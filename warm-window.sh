#!/usr/bin/env bash
# worker: sends one tiny claude ping.
# --due   = only ping when it's time. the scheduler calls it like that every minute.
#           "time" = 1 min after your real 5h window resets (read from claude's usage api).
#           the api is rate limited, so it's read about once per window, and when it can't
#           be read the interval from config is the fallback.
# --reset = just print the 5h reset as epoch seconds, "none" if no window is running.
set +e

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here" || exit 1
log="$here/warm.log"
cfg="$here/config.json"
state="$here/warm.state"
lock="$here/.warm.lock"

# launchd/cron give a bare PATH. the one baked in at install comes first, these are fallbacks
export PATH="$PATH:$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# ping lines are "exit=N", anything else (skips, notes) is a plain line stats ignores
logline() { lograw "exit=$1" "$2"; }
lograw() {
  local text
  text="$(printf '%s' "$2" | perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\s+/ /g' | sed 's/^ *//;s/ *$//')"
  [ -z "$text" ] && text="(no output)"
  printf '%s  %s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${text:0:220}" >> "$log"
  tail -n 500 "$log" > "$log.tmp" && mv "$log.tmp" "$log"
}

hm() { date -r "$1" '+%H:%M:%S' 2>/dev/null || date -d "@$1" '+%H:%M:%S'; }

# the claude login. macos keeps it in the keychain, linux in ~/.claude/.credentials.json
token() {
  if [ "$(uname -s)" = Darwin ]; then
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null
  else
    cat "$HOME/.claude/.credentials.json" 2>/dev/null
  fi | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null
}

# 5h reset from the same endpoint claude's /usage uses. prints epoch, "none", or fails.
# always the official host, never baseUrl, so the login never goes to a proxy.
# header goes in via stdin so the token doesn't show up in ps.
usage_reset() {
  local tok body
  tok="$(token)"; [ -n "$tok" ] || return 1
  body="$(printf 'Authorization: Bearer %s\nanthropic-beta: oauth-2025-04-20\n' "$tok" |
    curl -sf -m 15 -H @- https://api.anthropic.com/api/oauth/usage)" || return 1
  printf '%s' "$body" | jq -er '
    if (.five_hour | type) != "object" then error("no five_hour")
    elif .five_hour.resets_at == null then "none"
    else .five_hour.resets_at as $t
      # whole seconds, rounded (the api says 21:19:59.98 for a 21:20 reset)
      | ($t | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601)
        + (if ($t | test("\\.[5-9]")) then 1 else 0 end) | tostring end' 2>/dev/null
}

# powershell 5 writes a BOM, old jq chokes on it
cfgv() { perl -pe 's/^\xEF\xBB\xBF// if $. == 1' "$cfg" 2>/dev/null | jq -r "$1" 2>/dev/null; }

if ! command -v jq >/dev/null 2>&1; then logline 3 "jq not found"; exit 3; fi
if ! cfgv 'type == "object"' | grep -qx true; then logline 2 "config.json is broken (needs a json object)"; exit 2; fi

h="$(cfgv '.intervalHours // 5')"; m="$(cfgv '.intervalMinutes // 1')"
case "$h" in ''|*[!0-9]*) h=5; m=1 ;; esac
case "$m" in ''|*[!0-9]*) h=5; m=1 ;; esac
iv=$(( 10#$h * 3600 + 10#$m * 60 ))
[ "$iv" -ge 300 ] || iv=18060

if [ "${1-}" = "--reset" ]; then usage_reset; exit; fi

# state: <last ping> <its exit code> <next check> <5h reset, 0 = unknown>
last=0; code=0; next=""; reset=0
[ -f "$state" ] && read -r last code next reset < "$state"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
[ -n "$code" ] || code=0
case "$next" in *[!0-9]*) next="" ;; esac
case "$reset" in ''|*[!0-9]*) reset=0 ;; esac
save() { echo "$last $code $next $reset" > "$state"; }

if [ "${1-}" = "--due" ]; then
  now="$(date +%s)"
  # nothing planned yet (first run, or an old state file): check the window right away
  [ -n "$next" ] || next="$now"
  [ $(( next - now )) -gt 60 ] && exit 0
  # within the minute: wait for the exact second
  [ "$next" -gt "$now" ] && sleep $(( next - now ))
  now="$(date +%s)"

  r="$(usage_reset)"
  case "$r" in
    none) ;;   # no window running -> ping
    ''|*[!0-9]*)
      # api down or rate limited. only ping once the fallback interval is up, else look again in 5 min
      if [ $(( now - last )) -lt "$iv" ]; then next=$(( now + 300 )); save; exit 0; fi ;;
    *)
      if [ "$r" -gt "$now" ]; then
        # a window is already running (you used claude): don't ping, aim 1 min after it resets
        [ "$r" = "$reset" ] || lograw skip "window already running, resets $(hm "$r"), next ping $(hm $(( r + 60 )))"
        reset="$r"; next=$(( r + 60 )); save; exit 0
      fi ;;
  esac

  # never ping twice within 15 min on our own, e.g. when the api lags or auth is broken
  if [ $(( now - last )) -lt 900 ]; then next=$(( last + 900 )); save; exit 0; fi
fi

if ! mkdir "$lock" 2>/dev/null; then
  # leftover from a killed run
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
    rm -rf "$lock"; mkdir "$lock" 2>/dev/null || exit 75
  else
    exit 75   # another ping is running
  fi
fi
trap 'rm -rf "$lock"' EXIT

claude="$(command -v claude)"
if [ -z "$claude" ]; then
  logline 127 "claude command not found"
  last="$(date +%s)"; code=127; next=$(( last + 900 )); save
  exit 127
fi

prompt="$(cfgv '.prompt // ""')"
[ -n "$prompt" ] || prompt="Reply with only: ok"
# missing key -> haiku, explicit "" -> claude's own default
model="$(cfgv '.model // "haiku"')"
base="$(cfgv '.baseUrl // "https://api.anthropic.com"')"
[ -n "$base" ] || base="https://api.anthropic.com"

# hit the real subscription: official endpoint + oauth login, no api key, no proxy from user settings
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
export ANTHROPIC_BASE_URL="$base"

args=(-p --output-format text --strict-mcp-config --no-session-persistence --setting-sources project)
[ -n "$model" ] && args+=(--model "$model")
# -- so a prompt starting with "-" isn't read as a flag
args+=(-- "$prompt")

# 3 min hard stop so a hung claude can't block every later ping.
# claude gets its own process group and the whole group is killed, so no child procs get left behind.
# runs in the background so a TERM to this script can stop it (bash won't run traps during $(...))
perl -e '
  my $t = shift;
  my $pid = fork; exit 127 unless defined $pid;
  if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127 }
  setpgrp($pid, $pid);
  # also on TERM/INT/HUP (launchd stopping us), or claude gets orphaned with no timeout
  my $stop = sub { my $c = shift; sub { kill "TERM", -$pid; sleep 2; kill "KILL", -$pid; exit $c } };
  $SIG{ALRM} = $stop->(142); $SIG{TERM} = $stop->(143); $SIG{INT} = $stop->(130); $SIG{HUP} = $stop->(129);
  alarm $t;
  waitpid $pid, 0;
  exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
' 180 "$claude" "${args[@]}" > "$lock/out" 2>&1 < /dev/null &
pp=$!
trap 'kill -TERM "$pp" 2>/dev/null; wait "$pp"; logline 143 "stopped mid-ping"; exit 143' TERM INT HUP
wait "$pp"; code=$?
out="$(cat "$lock/out" 2>/dev/null)"
[ "$code" = 142 ] && out="timed out after 180s. $out"

last="$(date +%s)"
logline "$code" "$out"

# aim the next ping 1 min after the window this ping started resets
r="$(usage_reset)"
case "$r" in ''|none|*[!0-9]*) r=0 ;; esac
if [ "$r" -gt "$last" ]; then
  reset="$r"; next=$(( r + 60 ))
else
  reset=0; next=$(( last + 300 ))
  lograw note "couldn't read the 5h reset yet, checking again in 5 min"
fi
save
exit "$code"
