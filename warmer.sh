#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cfg="$here/config.json"
log="$here/warm.log"
worker="$here/warm-window.sh"
version="1.1.0"
tools=(claude codex agy)

say() { printf '%s\n' "$*"; }
die() { say "error: $*" >&2; exit 1; }
need_jq() { command -v jq >/dev/null 2>&1 || die "jq is required for warmer.sh"; }
cur_tool() { need_jq; jq -r '.tool // "claude"' "$cfg" | tr '[:upper:]' '[:lower:]'; }
valid_tool() { case "$1" in claude|codex|agy) return 0;; *) return 1;; esac; }

set_json() {
  need_jq
  local tmp="$cfg.tmp"
  jq "$@" "$cfg" > "$tmp"
  mv "$tmp" "$cfg"
}

cmd_for() { command -v "$1" 2>/dev/null || true; }

cmd_tools() {
  local cur; cur="$(cur_tool)"
  say "tools"
  for t in "${tools[@]}"; do
    mark=" "
    [ "$t" = "$cur" ] && mark="*"
    path="$(cmd_for "$t")"
    if [ -n "$path" ]; then say "  $mark $t  ok  $path"; else say "  $mark $t  missing"; fi
  done
}

cmd_status() {
  local tool; tool="$(cur_tool)"
  say "warmer"
  say "  tool  : $tool"
  say "  every : $(jq -r '.intervalHours' "$cfg")h $(jq -r '.intervalMinutes' "$cfg")m"
  [ -f "$log" ] && say "  last  : $(grep 'exit=' "$log" | tail -n 1)"
}

cmd_use() {
  [ $# -ge 1 ] || die "usage: warmer use <claude|codex|agy>"
  valid_tool "$1" || die "unknown tool '$1'. valid: claude | codex | agy"
  [ -n "$(cmd_for "$1")" ] || die "$1 is not installed or not on PATH"
  set_json --arg t "$1" '.tool=$t'
  say "using $1"
}

cmd_ping() {
  bash "$worker"
  [ -f "$log" ] && grep 'exit=' "$log" | tail -n 1
}

cmd_logs() {
  n="${1:-25}"
  [ -f "$log" ] || { say "no log yet"; return; }
  tail -n "$n" "$log"
}

cmd_interval() {
  [ $# -ge 1 ] || { say "current interval: $(jq -r '.intervalHours' "$cfg")h $(jq -r '.intervalMinutes' "$cfg")m"; return; }
  txt="$1"
  if [[ "$txt" =~ ^([0-9]+)h([0-9]+)m?$ ]]; then h="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
  elif [[ "$txt" =~ ^([0-9]+):([0-9]+)$ ]]; then h="${BASH_REMATCH[1]}"; m="${BASH_REMATCH[2]}"
  elif [[ "$txt" =~ ^([0-9]+)m?$ ]]; then h=$((txt / 60)); m=$((txt % 60))
  else die "can't parse interval '$txt'. try: 5h2m | 5:02 | 302"
  fi
  set_json --argjson h "$h" --argjson m "$m" '.intervalHours=$h | .intervalMinutes=$m'
  say "interval set to ${h}h ${m}m"
}

cmd_set() {
  [ $# -ge 2 ] || die "usage: warmer set <model|prompt|baseUrl> <value...>"
  key="$1"; shift; val="$*"; tool="$(cur_tool)"
  case "$key" in
    model)
      case "$tool" in
        claude) set_json --arg v "$val" '.model=$v' ;;
        codex) set_json --arg v "$val" '.codexModel=$v' ;;
        agy) set_json --arg v "$val" '.agyModel=$v' ;;
      esac ;;
    prompt) set_json --arg v "$val" '.prompt=$v' ;;
    baseUrl|baseurl) set_json --arg v "$val" '.baseUrl=$v' ;;
    tool) cmd_use "$val" ;;
    *) die "unknown key '$key'. valid: tool | model | prompt | baseUrl" ;;
  esac
  say "set $key = $val"
}

cmd_setup() {
  chmod +x "$worker" "$here/warmer.sh" "$here/setup.sh" 2>/dev/null || true
  say "warmer is at $here"
  say "add this folder to PATH if you want the command everywhere"
}

cmd_help() {
  cat <<'EOF'
warmer - keeps claude, codex, or agy warmed with a tiny scheduled ping

usage
  warmer [command] [args]

commands
  status
  tools
  use <claude|codex|agy>
  ping
  logs [N]
  config
  interval <spec>
  set model <m>
  set prompt <txt>
  set baseUrl <url>
  setup
  version
EOF
}

cmd="${1:-status}"; shift || true
case "$cmd" in
  status) cmd_status "$@" ;;
  tools|list) cmd_tools "$@" ;;
  use|switch) cmd_use "$@" ;;
  ping|now) cmd_ping "$@" ;;
  logs|log) cmd_logs "$@" ;;
  config) cat "$cfg" ;;
  interval) cmd_interval "$@" ;;
  set) cmd_set "$@" ;;
  setup) cmd_setup "$@" ;;
  version|-v) say "warmer $version" ;;
  help|-h|--help) cmd_help ;;
  *) die "unknown command: $cmd" ;;
esac
