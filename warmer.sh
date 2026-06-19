#!/usr/bin/env bash
# warmer - cli for the AI-cli window warmer (bash/cron edition). keeps each provider's rolling window fresh.
# scheduling backend is cron: one polling line per enabled provider, the worker self-gates on the interval.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cfg="$root/config.json"
log="$root/warm.log"
state="$root/warm.state"
worker="$root/warm-window.sh"
version="2.0.0-bash"

command -v jq >/dev/null 2>&1 || { echo "warmer: needs 'jq' on PATH (apt install jq / brew install jq)" >&2; exit 3; }

# ---------- colors ----------
if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[90m'; C=$'\033[36m'; Z=$'\033[0m'
else G=; R=; Y=; D=; C=; Z=; fi
ok()   { printf '%s%s%s\n' "$G" "$1" "$Z"; }
bad()  { printf '%s%s%s\n' "$R" "$1" "$Z"; }
warn() { printf '%s%s%s\n' "$Y" "$1" "$Z"; }
dim()  { printf '%s%s%s\n' "$D" "$1" "$Z"; }
head() { printf '\n%s%s%s\n' "$C" "$1" "$Z"; }

die() { bad "error: $1"; exit 1; }

# ---------- config helpers ----------
prefix() { jq -r '.taskPrefix' "$cfg"; }
prov_ids() { jq -r '.providers | keys_unsorted[]' "$cfg"; }
enabled_ids() { jq -r '.providers | to_entries[] | select(.value.enabled) | .key' "$cfg"; }
pget() { jq -r --arg id "$1" "$2" "$cfg"; }   # pget <id> '.providers[$id].xxx'
has_prov() { jq -e --arg id "$1" '.providers[$id]' "$cfg" >/dev/null 2>&1; }
validate() { has_prov "$1" || die "unknown provider '$1'. known: $(prov_ids | paste -sd, -)"; }

# mutate config in place; filter is the last arg, jq opts before it
cfg_jq() {
  local tmp="$cfg.$$"
  jq "$@" "$cfg" > "$tmp" && mv "$tmp" "$cfg"
}

# config is shared with the windows version, so cmds can be windows-style (%APPDATA%\npm\claude.cmd).
# expand %VARS%, and if it's clearly windows (backslash / .cmd|.exe|.bat) reduce to the bare cli name
# so PATH lookup finds the unix binary. real unix paths pass through.
norm_cmd() {
  local c="$1" v
  while [[ "$c" =~ %([A-Za-z_][A-Za-z0-9_]*)% ]]; do v="${BASH_REMATCH[1]}"; c="${c//%$v%/${!v-}}"; done
  if [[ "$c" == *\\* || "$c" == *.cmd || "$c" == *.exe || "$c" == *.bat ]]; then
    c="${c##*\\}"; c="${c##*/}"
    c="${c%.cmd}"; c="${c%.exe}"; c="${c%.bat}"
  fi
  printf '%s' "$c"
}

# is the provider's cli actually installed? path-like -> test exists, bare name -> look on PATH
detect() {
  local cmd; cmd="$(norm_cmd "$(pget "$1" '.providers[$id].cmd')")"
  case "$cmd" in
    */*) [ -e "$cmd" ];;
    *)   command -v "$cmd" >/dev/null 2>&1;;
  esac
}

# turn the first rest-arg into a list of ids.  mode: enabled | all | require
resolve_ids() {
  local mode="$1" arg="${2-}"
  if [ -z "$arg" ]; then
    case "$mode" in
      enabled) enabled_ids;;
      all)     prov_ids;;
      require) die "which provider? give an id or 'all'   (see: warmer list)";;
    esac
    return
  fi
  if [ "$arg" = all ]; then prov_ids; return; fi
  validate "$arg"; echo "$arg"
}

# ---------- cron helpers ----------
marker() { echo "# $(prefix)-$1"; }
# bake the current PATH into the line so the cron-spawned worker sees node/npm clis (cron's own PATH is
# bare). '%' is cron's newline metachar -> escape it so a windows-y PATH segment can't corrupt the line.
cron_line() {
  local pe="${PATH//%/\\%}"
  printf '*/5 * * * * PATH="%s" "%s" -p %s --due >/dev/null 2>&1 %s\n' "$pe" "$worker" "$1" "$(marker "$1")"
}
cur_cron() { crontab -l 2>/dev/null || true; }
task_exists() { cur_cron | grep -qF "$(marker "$1")"; }

register_task() {
  local id="$1" ih im
  ih="$(pget "$id" '.providers[$id].intervalHours // 0')"
  im="$(pget "$id" '.providers[$id].intervalMinutes // 0')"
  [ "$ih" = 0 ] && [ "$im" = 0 ] && die "[$id] interval is zero - set one first"
  { cur_cron | grep -vF "$(marker "$id")"; cron_line "$id"; } | crontab -
}
unregister_task() {
  cur_cron | grep -vF "$(marker "$1")" | crontab -
}
remove_legacy() {
  if cur_cron | grep -q '# ClaudeWindowWarmer'; then
    cur_cron | grep -v '# ClaudeWindowWarmer' | crontab -
    dim "  removed legacy ClaudeWindowWarmer cron entry"
  fi
}

# ---------- time helpers ----------
state_epoch() { grep "^$1=" "$state" 2>/dev/null | tail -1 | cut -d= -f2; }

human_span() {  # signed delta seconds -> "in 5h2m" / "5m ago"
  local d="$1" neg=0
  [ "$d" -lt 0 ] && { neg=1; d=$(( -d )); }
  local days=$(( d/86400 )) hrs=$(( (d%86400)/3600 )) mins=$(( (d%3600)/60 ))
  local s=""
  [ "$days" -gt 0 ] && s+="${days}d "
  [ "$hrs"  -gt 0 ] && s+="${hrs}h "
  s+="${mins}m"
  if [ "$neg" = 1 ]; then echo "$s ago"; else echo "in $s"; fi
}

next_span() {  # id -> human span of the next due time (from state + interval)
  local id="$1" last ih im interval
  last="$(state_epoch "$id")"
  [ -z "$last" ] && { echo "soon"; return; }
  ih="$(pget "$id" '.providers[$id].intervalHours // 0')"
  im="$(pget "$id" '.providers[$id].intervalMinutes // 0')"
  interval=$(( ih*3600 + im*60 ))
  human_span $(( last + interval - $(date +%s) ))
}

# ping log lines only (have exit=). optional id filter.
log_lines() {
  [ -f "$log" ] || return 0
  if [ -n "${1-}" ]; then grep 'exit=' "$log" | grep "\[$1\]"
  else grep 'exit=' "$log"; fi
}
log_count() { log_lines "${1-}" | grep -c . ; }

wait_for_ping() {  # id, before_count, timeout_sec
  local id="$1" before="$2" timeout="$3" waited=0 nowc
  while [ "$waited" -lt "$timeout" ]; do
    sleep 4; waited=$(( waited+4 ))
    nowc="$(log_count "$id")"
    [ "$nowc" -gt "$before" ] && break
  done
}

# ---------- subcommands ----------
show_detail() {
  local id="$1"
  head "Window Warmer - $(pget "$id" '.providers[$id].label') [$id]"
  printf '  enabled    : %s\n' "$([ "$(pget "$id" '.providers[$id].enabled')" = true ] && echo yes || echo no)"
  dim "  every      : $(pget "$id" '.providers[$id].intervalHours')h $(pget "$id" '.providers[$id].intervalMinutes')m   model=$(pget "$id" '.providers[$id].model // ""')   cmd=$(pget "$id" '.providers[$id].cmd')"
  if ! task_exists "$id"; then bad "  task NOT installed   ->  warmer install $id"; return; fi
  ok  "  cron       : installed (polls every 5m, gated to the interval)"
  local last; last="$(state_epoch "$id")"
  if [ -z "$last" ]; then dim "  last run   : not yet"; else
    dim "  last run   : $(date -d "@$last" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$last" '+%Y-%m-%d %H:%M:%S')"
  fi
  printf '  next ping  : %s\n' "$(next_span "$id")"
  local ll; ll="$(log_lines "$id" | tail -1)"
  [ -n "$ll" ] && dim "  last log   : $ll"
}

cmd_status() {
  local id="${1-}"
  if [ -n "$id" ]; then validate "$id"; show_detail "$id"; return; fi
  head "AI-CLI Window Warmer - all providers"
  printf '  %-12s %-20s %-4s %-9s %-7s %s\n' id provider on task every next
  while IFS= read -r pn; do
    local on task every next
    on="$([ "$(pget "$pn" '.providers[$id].enabled')" = true ] && echo yes || echo -)"
    task="$(task_exists "$pn" && echo cron || echo -)"
    every="$(pget "$pn" '.providers[$id].intervalHours')h$(pget "$pn" '.providers[$id].intervalMinutes')m"
    next="$(task_exists "$pn" && next_span "$pn" || echo -)"
    printf '  %-12s %-20s %-4s %-9s %-7s %s\n' "$pn" "$(pget "$pn" '.providers[$id].label')" "$on" "$task" "$every" "$next"
  done < <(prov_ids)
  dim "  detail: warmer status <id>    control: warmer enable|ping|install <id>    warmer list"
}

cmd_list() {
  head "Known providers"
  printf '  %-12s %-20s %-10s %-8s %-7s %s\n' id provider installed enabled every cmd
  while IFS= read -r pn; do
    local inst every
    inst="$(detect "$pn" && echo yes || echo no)"
    every="$(pget "$pn" '.providers[$id].intervalHours')h$(pget "$pn" '.providers[$id].intervalMinutes')m"
    printf '  %-12s %-20s %-10s %-8s %-7s %s\n' "$pn" "$(pget "$pn" '.providers[$id].label')" "$inst" \
      "$([ "$(pget "$pn" '.providers[$id].enabled')" = true ] && echo yes || echo no)" "$every" "$(pget "$pn" '.providers[$id].cmd')"
  done < <(prov_ids)
  dim "  enable one:  warmer enable <id>     fix its command:  warmer set <id> cmd <path>"
}

cmd_ping() {
  local ids; ids="$(resolve_ids enabled "${1-}")"
  [ -z "$ids" ] && { warn "nothing enabled to ping - try: warmer ping <id>  or  warmer setup"; return; }
  while IFS= read -r id; do
    local before; before="$(log_count "$id")"
    echo "pinging $id..."
    "$worker" -p "$id" >/dev/null 2>&1 || true
    wait_for_ping "$id" "$before" 150
    local ll; ll="$(log_lines "$id" | tail -1)"
    if echo "$ll" | grep -q 'exit=0'; then ok "  $ll"; else bad "  $ll"; fi
  done <<< "$ids"
}

cmd_logs() {
  [ -f "$log" ] || { warn "no log yet"; return; }
  local n=25 id=""
  for tok in "$@"; do
    if [[ "$tok" =~ ^[0-9]+$ ]]; then n="$tok"
    elif [ -n "$tok" ]; then validate "$tok"; id="$tok"; fi
  done
  if [ -n "$id" ]; then log_lines "$id" | tail -n "$n"; else tail -n "$n" "$log"; fi
}

cmd_follow() {
  [ -f "$log" ] || { warn "no log yet - waiting for first ping..."; : > "$log"; }
  dim "tailing warm.log (ctrl-c to stop)..."
  tail -n 10 -f "$log"
}

cmd_stats() {
  local id="${1-}"; [ -n "$id" ] && validate "$id"
  head "Ping stats${id:+ - $id}"
  local total okc fail rate
  total="$(log_count "$id")"
  [ "$total" -eq 0 ] && { warn "  no pings logged yet"; return; }
  okc="$(log_lines "$id" | grep -c 'exit=0')"
  fail=$(( total - okc ))
  rate="$(awk "BEGIN{printf \"%.1f\", 100*$okc/$total}")"
  echo "  total : $total"
  ok   "  ok    : $okc  ($rate%)"
  if [ "$fail" -gt 0 ]; then bad "  fail  : $fail"; else echo "  fail  : 0"; fi
  if [ -z "$id" ]; then
    dim "  by provider:"
    while IFS= read -r pn; do
      local pt; pt="$(log_count "$pn")"
      if [ "$pt" -gt 0 ]; then
        printf '    %-12s %s/%s ok\n' "$pn" "$(log_lines "$pn" | grep -c 'exit=0')" "$pt"
      fi
    done < <(prov_ids)
  fi
  if [ "$fail" -gt 0 ]; then
    bad "  last fail: $(log_lines "$id" | grep -v 'exit=0' | tail -1)"
  fi
}

cmd_config() { head "config.json"; cat "$cfg"; }

cmd_interval() {
  local id="${1-}"
  if [ -z "$id" ]; then
    head "intervals"
    while IFS= read -r pn; do
      printf '  %-12s %sh %sm\n' "$pn" "$(pget "$pn" '.providers[$id].intervalHours')" "$(pget "$pn" '.providers[$id].intervalMinutes')"
    done < <(prov_ids)
    return
  fi
  validate "$id"; shift
  if [ "$#" -eq 0 ]; then
    echo "current $id interval: $(pget "$id" '.providers[$id].intervalHours')h $(pget "$id" '.providers[$id].intervalMinutes')m"; return
  fi
  local hm; hm="$(parse_interval "$@")" || die "can't parse interval '$*'. try: 5h2m | 5:02 | 302 (minutes)"
  local H="${hm% *}" M="${hm#* }"
  H=$(( 10#$H )); M=$(( 10#$M ))   # strip leading zeros so jq --argjson doesn't choke on "02"
  [ "$H" = 0 ] && [ "$M" = 0 ] && die "interval can't be zero"
  cfg_jq --arg id "$id" --argjson h "$H" --argjson m "$M" \
    '.providers[$id].intervalHours=$h | .providers[$id].intervalMinutes=$m'
  if task_exists "$id"; then register_task "$id"; ok "$id interval set to ${H}h ${M}m and cron re-registered"
  else ok "$id interval set to ${H}h ${M}m"; fi
}

parse_interval() {  # echoes "H M"
  local txt; txt="$(echo "$*" | sed -E 's/^ +| +$//g')"
  if   [[ "$txt" =~ ^([0-9]+)[hH]([0-9]+)[mM]?$ ]]; then echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  elif [[ "$txt" =~ ^([0-9]+)[hH]$ ]];              then echo "${BASH_REMATCH[1]} 0"
  elif [[ "$txt" =~ ^([0-9]+):([0-9]+)$ ]];         then echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  elif [[ "$txt" =~ ^([0-9]+)[[:space:]]+([0-9]+)$ ]]; then echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
  elif [[ "$txt" =~ ^([0-9]+)[mM]?$ ]];             then local t="${BASH_REMATCH[1]}"; echo "$(( t/60 )) $(( t%60 ))"
  else return 1; fi
}

cmd_set() {
  [ "$#" -lt 3 ] && die "usage: warmer set <provider> <model|prompt|cmd|baseurl> <value...>"
  local id="$1"; validate "$id"
  local key; key="$(echo "$2" | tr '[:upper:]' '[:lower:]')"; shift 2
  local val="$*"
  case "$key" in
    model)  cfg_jq --arg id "$id" --arg v "$val" '.providers[$id].model=$v';;
    prompt) cfg_jq --arg id "$id" --arg v "$val" '.providers[$id].prompt=$v';;
    cmd)    cfg_jq --arg id "$id" --arg v "$val" '.providers[$id].cmd=$v';;
    baseurl) cfg_jq --arg id "$id" --arg v "$val" '.providers[$id].env.ANTHROPIC_BASE_URL=$v';;
    *) die "unknown key '$key'. valid: model | prompt | cmd | baseurl";;
  esac
  ok "set $id $key = $val"
  dim "(takes effect on the next ping - no reinstall needed)"
}

cmd_install() {
  local ids; ids="$(resolve_ids enabled "${1-}")"
  [ -z "$ids" ] && { warn "nothing enabled to install - name one (warmer install claude) or run warmer setup"; return; }
  while IFS= read -r id; do
    cfg_jq --arg id "$id" '.providers[$id].enabled=true'
    register_task "$id"
    ok "[$id] installed - next ping $(next_span "$id")"
  done <<< "$ids"
}

cmd_uninstall() {
  local ids any=0; ids="$(resolve_ids all "${1-}")"
  while IFS= read -r id; do
    if task_exists "$id"; then
      unregister_task "$id"
      cfg_jq --arg id "$id" '.providers[$id].enabled=false'
      ok "[$id] cron removed"; any=1
    fi
  done <<< "$ids"
  remove_legacy
  [ "$any" = 0 ] && warn "no warmer cron entries were installed"
}

cmd_enable() {
  local ids; ids="$(resolve_ids require "${1-}")"
  while IFS= read -r id; do
    cfg_jq --arg id "$id" '.providers[$id].enabled=true'
    register_task "$id"
    ok "[$id] enabled"
  done <<< "$ids"
}

cmd_disable() {
  local ids; ids="$(resolve_ids require "${1-}")"
  while IFS= read -r id; do
    task_exists "$id" && unregister_task "$id"
    cfg_jq --arg id "$id" '.providers[$id].enabled=false'
    warn "[$id] disabled (warmer enable $id to resume)"
  done <<< "$ids"
}

cmd_restart() {
  local ids; ids="$(resolve_ids enabled "${1-}")"
  [ -z "$ids" ] && { warn "nothing enabled to restart - try: warmer restart <id>"; return; }
  while IFS= read -r id; do register_task "$id"; ok "[$id] re-registered"; done <<< "$ids"
}

cmd_doctor() {
  head "Warmer doctor"
  local fail=0
  # shared wiring
  local cred="$HOME/.claude/.credentials.json"
  if [ -f "$cred" ]; then
    if jq -e '.claudeAiOauth' "$cred" >/dev/null 2>&1; then ok "  [ok]  subscription oauth present (claude/glm)"
    else warn "  [??]  credentials.json has no oauth block"; fi
  else warn "  [??]  no ~/.claude/.credentials.json (claude/glm need it - run 'claude' once to log in)"; fi
  if command -v crontab >/dev/null 2>&1; then ok "  [ok]  crontab available"; else bad "  [!!]  no crontab - cron scheduling won't work"; fail=$((fail+1)); fi

  local ids; ids="$(resolve_ids enabled "${1-}")"
  [ -z "$ids" ] && { warn "  nothing enabled - run warmer setup or warmer enable <id>"; return; }
  while IFS= read -r id; do
    head "  $(pget "$id" '.providers[$id].label') [$id]"
    if detect "$id"; then ok "    [ok]  cmd found ($(pget "$id" '.providers[$id].cmd'))"
    else bad "    [!!]  cmd '$(pget "$id" '.providers[$id].cmd')' not found - warmer set $id cmd <path>"; fail=$((fail+1)); fi
    if task_exists "$id"; then ok "    [ok]  cron registered (next $(next_span "$id"))"
    else warn "    [??]  cron not registered - warmer install $id"; fi
  done <<< "$ids"
  # live ping each
  dim "  ...running live test ping(s)..."
  while IFS= read -r id; do
    local before; before="$(log_count "$id")"
    "$worker" -p "$id" >/dev/null 2>&1 || true
    wait_for_ping "$id" "$before" 150
    local ll; ll="$(log_lines "$id" | tail -1)"
    if echo "$ll" | grep -q 'exit=0'; then ok "  [ok]  $id -> $ll"; else bad "  [!!]  $id -> $ll"; fail=$((fail+1)); fi
  done <<< "$ids"
  echo
  if [ "$fail" = 0 ]; then ok "all good."; else bad "$fail problem(s) found."; fi
}

cmd_setup() {
  head "Setting up the 'warmer' global command"
  chmod +x "$root/warmer.sh" "$worker" 2>/dev/null || true
  # 1. shell function in the login shell rc
  local rc
  case "${SHELL##*/}" in
    zsh) rc="$HOME/.zshrc";;
    *)   rc="$HOME/.bashrc";;
  esac
  [ -f "$rc" ] || : > "$rc"
  if ! grep -q 'function warmer\|warmer()' "$rc" 2>/dev/null; then
    printf '\nwarmer() { "%s" "$@"; }\n' "$root/warmer.sh" >> "$rc"
    ok "  added 'warmer' function to $rc"
  else dim "  shell function already present"; fi
  # 2. migrate off the old single-provider entry
  remove_legacy
  # 3. auto-detect installed clis; enable + register (claude always on)
  head "Auto-detecting installed CLIs"
  while IFS= read -r id; do
    if detect "$id" || [ "$id" = claude ]; then
      cfg_jq --arg id "$id" '.providers[$id].enabled=true'
      ok "  [found] $id  ($(pget "$id" '.providers[$id].label'))"
    else
      dim "  [skip]  $id  (cmd '$(pget "$id" '.providers[$id].cmd')' not on PATH)"
    fi
  done < <(prov_ids)
  while IFS= read -r id; do register_task "$id"; done < <(enabled_ids)
  ok "  cron entries registered for enabled providers"
  echo
  warn "run:  source $rc   (or open a new shell), then:  warmer status"
}

cmd_open() {
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$root"
  elif command -v open >/dev/null 2>&1; then open "$root"
  else echo "$root"; fi
}

cmd_help() {
cat <<'EOF'
warmer - keeps each AI-cli's rolling usage window freshly cycling (bash/cron edition)

USAGE
  warmer [command] [provider] [args]

  most commands take an optional <provider> id (claude, codex, antigravity, kimi,
  qwen, glm, copilot, grok). omit it and info commands cover all providers,
  control commands act on all *enabled* ones. 'all' forces every provider.

INFO
  status [id]        per-provider table, or detail for one    (default)
  list               every provider: installed? enabled? interval, cmd
  stats [id]         success/fail counts from the log
  logs [N] [id]      last N log lines (optionally one provider)
  follow             live-tail the log
  config             print config.json
  doctor [id]        health check + live test ping(s)
  version

CONTROL
  ping [id|all]      fire a ping now
  install [id|all]   register cron poll line(s)
  uninstall [id|all] remove them   (no arg = all)
  enable <id|all>    register + mark enabled
  disable <id|all>   remove + mark disabled
  restart [id|all]   re-register (after a hand edit)
  setup              wire up the global command + auto-detect & install
  open               open the warmer folder

TUNING
  interval <id> <spec>   change cadence:  warmer interval claude 5h2m | 5:02 | 302
  set <id> model <m>     warmer set glm model glm-4.6
  set <id> prompt <txt>  change the ping text
  set <id> cmd <path>    fix the cli command/path
  set <id> baseurl <url> override the api endpoint (env ANTHROPIC_BASE_URL)
EOF
}

# ---------- dispatch ----------
cmd="${1:-status}"; [ "$#" -gt 0 ] && shift
case "$cmd" in
  status)              cmd_status "${1-}";;
  list|ls)             cmd_list;;
  stats|history)       cmd_stats "${1-}";;
  logs|log)            cmd_logs "$@";;
  follow|tail)         cmd_follow;;
  config)              cmd_config;;
  doctor|test)         cmd_doctor "${1-}";;
  ping|now)            cmd_ping "${1-}";;
  install)             cmd_install "${1-}";;
  uninstall|remove)    cmd_uninstall "${1-}";;
  enable)              cmd_enable "${1-}";;
  disable|pause)       cmd_disable "${1-}";;
  restart)             cmd_restart "${1-}";;
  setup)               cmd_setup;;
  open)                cmd_open;;
  interval)            cmd_interval "$@";;
  set)                 cmd_set "$@";;
  version|-v)          echo "warmer $version";;
  help|-h|--help)      cmd_help;;
  *)                   bad "unknown command: $cmd"; cmd_help; exit 1;;
esac
