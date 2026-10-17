#!/usr/bin/env bash
# warmer - keeps the claude 5h usage window cycling with a tiny scheduled ping.
# macos uses a launchd agent (cron can't read the keychain login), linux uses cron.
# both just run the worker every 5 min with --due, the worker decides if the interval is up.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cfg="$here/config.json"
log="$here/warm.log"
state="$here/warm.state"
worker="$here/warm-window.sh"
version="2.0.0"
os="$(uname -s)"

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[90m'; C=$'\033[36m'; Z=$'\033[0m'
else G=; R=; Y=; D=; C=; Z=; fi
ok()   { printf '%s%s%s\n' "$G" "$*" "$Z"; }
bad()  { printf '%s%s%s\n' "$R" "$*" "$Z"; }
warn() { printf '%s%s%s\n' "$Y" "$*" "$Z"; }
dim()  { printf '%s%s%s\n' "$D" "$*" "$Z"; }
title() { printf '\n%s%s%s\n' "$C" "$*" "$Z"; }
die()  { bad "error: $*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq / apt install jq)"

cfgv() { perl -pe 's/^\xEF\xBB\xBF// if $. == 1' "$cfg" | jq -r "$1"; }
set_json() {
  local tmp="$cfg.tmp"
  perl -pe 's/^\xEF\xBB\xBF// if $. == 1' "$cfg" | jq "$@" > "$tmp" && mv "$tmp" "$cfg"
}

ival_h() { cfgv '.intervalHours // 5'; }
ival_m() { cfgv '.intervalMinutes // 1'; }
model()  { local m; m="$(cfgv '.model // "haiku"')"; [ -n "$m" ] && echo "$m" || echo default; }
# interval in seconds, same fallback as the worker
ival_s() {
  local h m; h="$(ival_h)"; m="$(ival_m)"
  case "$h" in ''|*[!0-9]*) h=5; m=1 ;; esac
  case "$m" in ''|*[!0-9]*) h=5; m=1 ;; esac
  local s=$(( 10#$h * 3600 + 10#$m * 60 )); [ "$s" -ge 300 ] || s=18060
  echo "$s"
}

fmt_ts() { date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M'; }
span() {
  local s="$1" out="" sfx=""
  if [ "$s" -lt 0 ]; then s=$(( -s )); sfx=" ago"; else out="in "; fi
  [ $(( s / 3600 )) -gt 0 ] && out="$out$(( s / 3600 ))h "
  echo "$out$(( s % 3600 / 60 ))m$sfx"
}

log_lines() { [ -f "$log" ] && grep 'exit=' "$log" || true; }
log_count() { log_lines | wc -l | tr -d ' '; }

# ---------- scheduler ----------
label() { cfgv '.taskName // "Warmer"' | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.\n-' '-'; }
plist() { echo "$HOME/Library/LaunchAgents/$(label).plist"; }
dom="gui/$(id -u)"
marker() { echo "# $(label)"; }
cur_cron() { crontab -l 2>/dev/null || true; }
# our cron line = ends exactly with the marker. 1 = print ours, 0 = print the rest
cron_pick() {
  local cur; cur="$(cur_cron)"
  printf '%s' "$cur" | awk -v m="$(marker)" -v want="$1" '{
    mine = (length($0) > length(m) && substr($0, length($0) - length(m) + 1) == m)
    if (mine == want) print
  }'
}
xml() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

backend() { [ "$os" = Darwin ] && echo launchd || echo cron; }

# prints: on | paused | off
sched_state() {
  if [ "$os" = Darwin ]; then
    [ -f "$(plist)" ] || { echo off; return; }
    launchctl print "$dom/$(label)" >/dev/null 2>&1 && echo on || echo paused
  else
    local line; line="$(cron_pick 1 | tail -n 1)"
    [ -z "$line" ] && { echo off; return; }
    case "$line" in '#'*) echo paused ;; *) echo on ;; esac
  fi
}

load_agent() {
  local i
  launchctl bootout "$dom/$(label)" 2>/dev/null || true
  launchctl enable "$dom/$(label)"
  # bootstrap right after bootout can race, retry a bit
  for i in 1 2 3 4 5; do
    launchctl bootstrap "$dom" "$(plist)" 2>/dev/null && return 0
    sleep 1
  done
  die "launchctl bootstrap failed for $(plist)"
}

register() {
  if [ "$os" = Darwin ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$(plist)" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$(xml "$(label)")</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml "$worker")</string>
    <string>--due</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(xml "$PATH")</string>
  </dict>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$(xml "$here/launchd.log")</string>
</dict>
</plist>
EOF
    load_agent
  else
    command -v crontab >/dev/null 2>&1 || die "crontab not found"
    # cron treats % as newline, escape it
    local pe="${PATH//%/\\%}"
    { cron_pick 0
      printf '*/5 * * * * PATH="%s" /bin/bash "%s" --due >/dev/null 2>&1 %s\n' "$pe" "$worker" "$(marker)"
    } | crontab -
  fi
}

unregister() {
  if [ "$os" = Darwin ]; then
    launchctl bootout "$dom/$(label)" 2>/dev/null || true
    rm -f "$(plist)"
  else
    cron_pick 0 | crontab -
  fi
}

# comment our cron line in/out. on = 1 uncomments
cron_toggle() {
  local cur; cur="$(cur_cron)"
  printf '%s' "$cur" | awk -v m="$(marker)" -v on="$1" '{
    if (length($0) > length(m) && substr($0, length($0) - length(m) + 1) == m) {
      if (on == 1) sub(/^#+/, ""); else if (substr($0, 1, 1) != "#") $0 = "#" $0
    }
    print
  }' | crontab -
}

# disable too, or launchd loads the plist again at the next login
pause() {
  if [ "$os" = Darwin ]; then
    launchctl bootout "$dom/$(label)" 2>/dev/null || true
    launchctl disable "$dom/$(label)"
  else cron_toggle 0; fi
}
resume() { if [ "$os" = Darwin ]; then load_agent; else cron_toggle 1; fi; }

# ---------- commands ----------
cmd_status() {
  title "warmer"
  dim "  model    : $(model)"
  dim "  endpoint : $(cfgv '.baseUrl // "https://api.anthropic.com"')"
  dim "  every    : $(ival_h)h $(ival_m)m"
  case "$(sched_state)" in
    on)     ok   "  schedule : on ($(backend), checks every 5m)" ;;
    paused) warn "  schedule : paused -> warmer enable" ;;
    off)    bad  "  schedule : not installed -> warmer install" ;;
  esac
  local last="" code="" now next
  [ -f "$state" ] && read -r last code < "$state"
  case "$last" in ''|*[!0-9]*) last="" ;; esac
  if [ -n "$last" ]; then
    now="$(date +%s)"
    next=$(( last + $(ival_s) ))
    # same retry rule as the worker
    [ "$code" = 0 ] || [ $(( next - last )) -le 900 ] || next=$(( last + 900 ))
    [ "$next" -lt "$now" ] && next="$now"
    echo "  next     : $(fmt_ts "$next") ($(span $(( next - now ))))"
  else
    echo "  next     : on the next check (no ping yet)"
  fi
  local ll; ll="$(log_lines | tail -n 1)"
  [ -n "$ll" ] && dim "  last log : $ll"
  return 0
}

cmd_ping() {
  local before code ll
  before="$(log_count)"
  echo "pinging claude..."
  bash "$worker"; code=$?
  if [ "$code" = 75 ]; then warn "another ping is already running, try again in a minute"; return 1; fi
  ll="$(log_lines | tail -n 1)"
  if [ "$(log_count)" -le "$before" ] && [ "$before" -lt 500 ]; then bad "  no new log line (exit $code)"; return 1; fi
  if [ "$code" = 0 ]; then ok "  $ll"; else bad "  $ll"; return 1; fi
}

cmd_logs() {
  local n="${1:-25}"
  case "$n" in ''|*[!0-9]*) die "usage: warmer logs [N]" ;; esac
  [ -f "$log" ] || { warn "no log yet"; return 0; }
  tail -n "$n" "$log"
}

cmd_follow() {
  [ -f "$log" ] || { warn "no log yet - waiting for first ping..."; : > "$log"; }
  dim "tailing warm.log (ctrl-c to stop)..."
  tail -n 10 -f "$log"
}

cmd_stats() {
  local total okc fail
  title "ping stats"
  total="$(log_count)"
  [ "$total" = 0 ] && { warn "  no pings logged yet"; return 0; }
  okc="$(log_lines | grep -c '  exit=0  ' || true)"
  fail=$(( total - okc ))
  echo "  total : $total"
  ok   "  ok    : $okc  ($(( 100 * okc / total ))%)"
  if [ "$fail" -gt 0 ]; then bad "  fail  : $fail"; else echo "  fail  : 0"; fi
  dim  "  span  : $(log_lines | head -n 1 | cut -c1-19)  ->  $(log_lines | tail -n 1 | cut -c1-19)"
  [ "$fail" -gt 0 ] && bad "  last fail: $(log_lines | grep -v '  exit=0  ' | tail -n 1)"
  return 0
}

parse_interval() {
  local t; t="$(printf '%s' "$*" | tr '[:upper:]' '[:lower:]')"
  # "5 1" = 5h 1m, like the windows version
  local re_sp='^ *([0-9]+) +([0-9]+) *$'
  if [[ "$t" =~ $re_sp ]]; then echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"; return 0; fi
  t="$(printf '%s' "$t" | tr -d ' ')"
  local re_hm='^([0-9]+)h([0-9]+)m?$' re_h='^([0-9]+)h$' re_c='^([0-9]+):([0-9]+)$' re_m='^([0-9]+)m?$'
  if   [[ "$t" =~ $re_hm ]]; then echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  elif [[ "$t" =~ $re_h ]];  then echo "${BASH_REMATCH[1]} 0"
  elif [[ "$t" =~ $re_c ]];  then echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  elif [[ "$t" =~ $re_m ]];  then local n=$(( 10#${BASH_REMATCH[1]} )); echo "$(( n / 60 )) $(( n % 60 ))"
  else return 1; fi
}

cmd_interval() {
  [ $# -ge 1 ] || { echo "current interval: $(ival_h)h $(ival_m)m"; return 0; }
  local hm h m
  hm="$(parse_interval "$@")" || die "can't parse interval '$*'. try: 5h1m | 5:01 | 301"
  h=$(( 10#${hm% *} )); m=$(( 10#${hm#* } ))
  # carry minutes over 59 into hours
  h=$(( h + m / 60 )); m=$(( m % 60 ))
  [ $(( h * 60 + m )) -ge 5 ] || die "interval must be at least 5m (the scheduler checks every 5m)"
  set_json --argjson h "$h" --argjson m "$m" '.intervalHours=$h | .intervalMinutes=$m'
  ok "interval set to ${h}h ${m}m"
  dim "(takes effect on the next check, no reinstall needed)"
}

cmd_set() {
  [ $# -ge 2 ] || die "usage: warmer set <model|prompt|baseUrl> <value...>"
  local key; key="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"; shift
  local val="$*"
  case "$key" in
    model)   set_json --arg v "$val" '.model=$v' ;;
    prompt)  set_json --arg v "$val" '.prompt=$v' ;;
    baseurl) set_json --arg v "$val" '.baseUrl=$v' ;;
    *) die "unknown key '$key'. valid: model | prompt | baseUrl" ;;
  esac
  ok "set $key = $val"
  dim "(takes effect on the next ping)"
}

cmd_install()   { register; ok "installed ($(backend)) - pings now if due, then every $(ival_h)h $(ival_m)m"; }
cmd_uninstall() {
  [ "$(sched_state)" = off ] && { warn "wasn't installed"; return 0; }
  unregister; ok "removed the $(backend) schedule"
}
cmd_enable() {
  case "$(sched_state)" in
    off) die "not installed -> warmer install" ;;
    on)  dim "already on" ;;
    *)   resume; ok "enabled" ;;
  esac
}
cmd_disable() {
  case "$(sched_state)" in
    off) die "not installed" ;;
    *)   pause; warn "paused (warmer enable to resume)" ;;
  esac
}
cmd_restart() { register; ok "re-registered"; }

claude_auth() {
  # macos keeps the login in the keychain, linux/windows in ~/.claude/.credentials.json
  [ -f "$HOME/.claude/.credentials.json" ] && return 0
  [ "$os" = Darwin ] && security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1
}

cmd_doctor() {
  title "warmer doctor"
  local fail=0 c st
  if [ "$(cfgv 'type == "object"' 2>/dev/null)" = true ]; then ok "  [ok]  config.json valid (model=$(model), every $(ival_h)h $(ival_m)m)"
  else bad "  [!!]  config.json broken"; fail=$((fail+1)); fi
  c="$(command -v claude || true)"
  if [ -n "$c" ]; then ok "  [ok]  claude cli ($c)"; else bad "  [!!]  claude cli not on PATH"; fail=$((fail+1)); fi
  if claude_auth; then ok "  [ok]  claude login found"; else bad "  [!!]  no claude login - run 'claude' once and sign in"; fail=$((fail+1)); fi
  st="$(sched_state)"
  case "$st" in
    on)     ok   "  [ok]  $(backend) schedule on" ;;
    paused) warn "  [??]  $(backend) schedule paused -> warmer enable" ;;
    off)    bad  "  [!!]  not scheduled -> warmer install"; fail=$((fail+1)) ;;
  esac
  case "$here" in
    "$HOME/Desktop"*|"$HOME/Documents"*|"$HOME/Downloads"*)
      [ "$os" = Darwin ] && warn "  [??]  folder is in a macos-protected place, launchd may get 'operation not permitted'. move it, e.g. ~/warmer" ;;
  esac
  dim "  ...running a live test ping..."
  if cmd_ping >/dev/null 2>&1; then ok "  [ok]  live ping -> $(log_lines | tail -n 1)"
  else bad "  [!!]  live ping failed -> $(log_lines | tail -n 1)"; fail=$((fail+1)); fi
  echo
  if [ "$fail" = 0 ]; then ok "all good."; else bad "$fail problem(s) found."; return 1; fi
}

cmd_setup() {
  title "setting up warmer"
  chmod +x "$worker" "$here/warmer.sh" "$here/setup.sh" 2>/dev/null || true
  local rc line tmp
  # macos terminals start login shells, and login bash reads .bash_profile, not .bashrc
  case "${SHELL##*/}" in
    zsh) rc="$HOME/.zshrc" ;;
    *)   if [ "$os" = Darwin ]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
  esac
  line="warmer() { \"$here/warmer.sh\" \"\$@\"; }"
  [ -f "$rc" ] || : > "$rc"
  if grep -qxF "$line" "$rc"; then
    dim "  shell function already points here ($rc)"
  else
    # drop an old warmer() line that points somewhere else, then add ours
    tmp="$(mktemp)"
    grep -v '^warmer() {' "$rc" > "$tmp" || true
    printf '\n%s\n' "$line" >> "$tmp"
    cat "$tmp" > "$rc"; rm -f "$tmp"
    ok "  added warmer function to $rc"
  fi
  register
  ok "  $(backend) schedule installed"
  echo
  warn "open a new terminal, then: warmer status"
}

cmd_open() { if [ "$os" = Darwin ]; then open "$here"; else xdg-open "$here" >/dev/null 2>&1 || echo "$here"; fi; }

cmd_help() {
  cat <<'EOF'
warmer - keeps the claude 5h usage window cycling with a tiny scheduled ping

usage
  warmer [command] [args]

info
  status            schedule state, last/next ping (default)
  stats             success/fail counts from the log
  logs [N]          last N log lines (default 25)
  follow            live-tail the log
  config            print config.json
  doctor            health check + a live test ping
  version

control
  ping              ping claude right now
  install           install the schedule (launchd on macos, cron on linux)
  uninstall         remove the schedule
  enable / disable  resume / pause without uninstalling
  restart           re-register the schedule
  setup             add the warmer shell function + install
  open              open the warmer folder

tuning
  interval <spec>   e.g. warmer interval 5h1m | 5:01 | 301
  set model <m>     e.g. warmer set model haiku
  set prompt <txt>  change the ping text
  set baseUrl <url> override the api endpoint
EOF
}

cmd="$(printf '%s' "${1:-status}" | tr '[:upper:]' '[:lower:]')"; shift || true
case "$cmd" in
  help|-h|--help|version|-v|config) ;;
  *) [ "$(cfgv 'type == "object"' 2>/dev/null)" = true ] || die "config.json is broken (needs a json object) ($cfg)" ;;
esac
case "$cmd" in
  status)               cmd_status ;;
  stats|history)        cmd_stats ;;
  logs|log)             cmd_logs "$@" ;;
  follow|tail)          cmd_follow ;;
  config)               cat "$cfg" ;;
  doctor|test)          cmd_doctor ;;
  ping|now)             cmd_ping ;;
  install)              cmd_install ;;
  uninstall|remove)     cmd_uninstall ;;
  enable)               cmd_enable ;;
  disable|pause)        cmd_disable ;;
  restart)              cmd_restart ;;
  setup)                cmd_setup ;;
  open)                 cmd_open ;;
  interval)             cmd_interval "$@" ;;
  set)                  cmd_set "$@" ;;
  version|-v)           echo "warmer $version" ;;
  help|-h|--help)       cmd_help ;;
  *)                    bad "unknown command: $cmd"; cmd_help; exit 1 ;;
esac
