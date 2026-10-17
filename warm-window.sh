#!/usr/bin/env bash
# worker: sends one tiny claude ping.
# --due = only ping when the interval is up. the scheduler calls it like that every 5 min.
set +e

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here" || exit 1
log="$here/warm.log"
cfg="$here/config.json"
state="$here/warm.state"
lock="$here/.warm.lock"

# launchd/cron give a bare PATH. the one baked in at install comes first, these are fallbacks
export PATH="$PATH:$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

logline() {
  local text
  text="$(printf '%s' "$2" | perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\s+/ /g' | sed 's/^ *//;s/ *$//')"
  [ -z "$text" ] && text="(no output)"
  printf '%s  exit=%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${text:0:220}" >> "$log"
  tail -n 500 "$log" > "$log.tmp" && mv "$log.tmp" "$log"
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

if [ "${1-}" = "--due" ] && [ -f "$state" ]; then
  read -r last code < "$state"
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  wait=$iv
  # failed last time -> retry sooner, but not every 5 min forever
  [ "$code" = 0 ] || { [ "$iv" -gt 900 ] && wait=900; }
  [ $(( $(date +%s) - last )) -lt "$wait" ] && exit 0
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
  echo "$(date +%s) 127" > "$state"
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

logline "$code" "$out"
echo "$(date +%s) $code" > "$state"
exit "$code"
