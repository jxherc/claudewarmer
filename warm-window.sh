#!/usr/bin/env bash
# worker the WindowWarmer cron jobs run each cycle. one tiny ping -> a fresh usage window starts.
# usage: warm-window.sh -p <provider> [--due]   (defaults to claude so a bare call still works)
# --due = self-gate: only ping if at least the configured interval has passed since the last attempt.
#         cron polls often and lets this decide, since cron can't express an arbitrary 5h2m cadence.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cfg="$here/config.json"
log="$here/warm.log"
state="$here/warm.state"   # per-provider "id=<epoch of last attempt>", drives the --due gate

# cron hands us a bare PATH (/usr/bin:/bin) so node/npm global clis vanish. widen it to the usual
# spots so `claude`, `codex`, etc. resolve the same as in an interactive shell.
PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/bin:$HOME/.bun/bin:$HOME/.deno/bin"
# nvm's current node bin, if present
if [ -n "${NVM_BIN:-}" ]; then PATH="$NVM_BIN:$PATH"
elif [ -d "$HOME/.nvm/versions/node" ]; then
  nb="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
  [ -n "$nb" ] && PATH="$nb:$PATH"
fi
export PATH

prov=claude
due=0
while [ $# -gt 0 ]; do
  case "$1" in
    -p|-Provider|--provider) prov="$2"; shift 2;;
    --due) due=1; shift;;
    *) prov="$1"; shift;;   # bare id, back-compat
  esac
done

command -v jq >/dev/null 2>&1 || { echo "warm-window: jq not installed" >&2; exit 3; }

ts="$(date '+%Y-%m-%d %H:%M:%S')"
now="$(date +%s)"

logline() {  # code, msg...
  local code="$1"; shift
  local msg="$*"
  msg="$(printf '%s' "$msg" | tr '\n\r\t' '   ' | tr -s ' ')"
  msg="${msg# }"
  [ "${#msg}" -gt 220 ] && msg="${msg:0:220}"
  printf '%s  [%s]  exit=%s  %s\n' "$ts" "$prov" "$code" "$msg" >> "$log"
}

# advance this provider's last-attempt stamp so a poll/fail doesn't re-ping every cycle
set_state() {
  local tmp="$state.$$"
  { grep -v "^${prov}=" "$state" 2>/dev/null; echo "${prov}=${now}"; } > "$tmp" && mv "$tmp" "$state"
}

q() { jq -r --arg id "$prov" "$1" "$cfg" 2>/dev/null; }

# config is shared with the windows version, so cmds can be windows-style (%APPDATA%\npm\claude.cmd).
# on unix: expand %VARS%, and if it's clearly a windows path/extension, reduce to the bare cli name so
# PATH lookup finds the unix binary (claude.cmd -> claude). real unix paths pass through untouched.
norm_cmd() {
  local c="$1" v
  while [[ "$c" =~ %([A-Za-z_][A-Za-z0-9_]*)% ]]; do v="${BASH_REMATCH[1]}"; c="${c//%$v%/${!v-}}"; done
  if [[ "$c" == *\\* || "$c" == *.cmd || "$c" == *.exe || "$c" == *.bat ]]; then
    c="${c##*\\}"; c="${c##*/}"          # basename, either separator
    c="${c%.cmd}"; c="${c%.exe}"; c="${c%.bat}"
  fi
  printf '%s' "$c"
}

# provider must exist
jq -e --arg id "$prov" '.providers[$id]' "$cfg" >/dev/null 2>&1 || { logline 2 "unknown provider '$prov'"; exit 2; }

ih="$(q '.providers[$id].intervalHours // 0')"
im="$(q '.providers[$id].intervalMinutes // 0')"

# --due gate: bail early if we pinged less than one interval ago
if [ "$due" = 1 ]; then
  interval=$(( ih*3600 + im*60 ))
  last="$(grep "^${prov}=" "$state" 2>/dev/null | tail -1 | cut -d= -f2)"
  if [ -n "$last" ] && [ "$(( now - last ))" -lt "$interval" ]; then exit 0; fi
fi

cmd="$(q '.providers[$id].cmd')"
model="$(q '.providers[$id].model // ""')"
prompt="$(q '.providers[$id].prompt // ""')"

# resolve the command. a real path must exist; a bare name we trust to PATH and let it fail loudly.
rcmd="$(norm_cmd "$cmd")"
case "$rcmd" in
  */*) if [ ! -e "$rcmd" ]; then logline 127 "command not found at $rcmd"; set_state; exit 127; fi;;
  *)   if ! command -v "$rcmd" >/dev/null 2>&1; then logline 127 "command '$rcmd' not on PATH"; set_state; exit 127; fi;;
esac

# build args: substitute {prompt}/{model}. if model is blank, drop {model} AND the flag right before it,
# so a "-m {model}" / "--model {model}" pair vanishes clean instead of passing an empty value.
hasModel=0; [ -n "$model" ] && hasModel=1
rawargs=()
while IFS= read -r a; do rawargs+=("$a"); done < <(q '.providers[$id].args[]')
args=()
for a in "${rawargs[@]}"; do
  if [ "$a" = "{model}" ]; then
    if [ "$hasModel" = 1 ]; then args+=("$model")
    elif [ "${#args[@]}" -gt 0 ]; then unset 'args[$(( ${#args[@]} - 1 ))]'; fi   # pop the trailing flag
    continue
  fi
  a="${a//\{prompt\}/$prompt}"
  a="${a//\{model\}/$model}"
  args+=("$a")
done

# some boxes route a cli through a 3rd-party proxy via the env. provider config can force the right
# endpoint and ditch inherited keys so the ping hits the real account. (process exits right after,
# so no need to restore any of this.)
while IFS=$'\t' read -r k v; do [ -n "$k" ] && export "$k=$v"; done \
  < <(q '.providers[$id].env // {} | to_entries[] | "\(.key)\t\(.value)"')
while IFS= read -r k; do [ -n "$k" ] && unset "$k"; done \
  < <(q '.providers[$id].clearEnv // [] | .[]')

# </dev/null closes stdin so the cli doesn't sit waiting on it
resp="$("$rcmd" "${args[@]}" </dev/null 2>&1)"
code=$?

logline "$code" "$resp"
set_state

# don't let the log grow forever
if [ -f "$log" ] && [ "$(wc -l < "$log")" -gt 500 ]; then
  tail -n 500 "$log" > "$log.$$" && mv "$log.$$" "$log"
fi

exit "$code"
