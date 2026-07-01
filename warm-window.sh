#!/usr/bin/env bash
set +e

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here" || exit 1
log="$here/warm.log"
cfg="$here/config.json"
ts="$(date '+%Y-%m-%d %H:%M:%S')"

tool="$(jq -r '.tool // "claude"' "$cfg" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
prompt="$(jq -r '.prompt // "Reply with only: ok"' "$cfg" 2>/dev/null)"

logline() {
  local code="$1" text="$2"
  text="$(printf '%s' "$text" | perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g; s/\s+/ /g' | sed 's/^ *//;s/ *$//')"
  [ -z "$text" ] && text="(no output)"
  text="${text:0:220}"
  printf '%s  tool=%s  exit=%s  %s\n' "$ts" "$tool" "$code" "$text" >> "$log"
}

case "$tool" in
  claude|codex|agy) ;;
  *) logline 2 "unsupported tool. valid: claude | codex | agy"; exit 2 ;;
esac

if ! command -v "$tool" >/dev/null 2>&1; then
  logline 127 "$tool command not found"
  exit 127
fi

out=""
case "$tool" in
  claude)
    model="$(jq -r '.model // ""' "$cfg" 2>/dev/null)"
    export ANTHROPIC_BASE_URL="$(jq -r '.baseUrl // "https://api.anthropic.com"' "$cfg" 2>/dev/null)"
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
    if [ -n "$model" ]; then
      out="$(claude -p "$prompt" --model "$model" --output-format text --strict-mcp-config 2>&1)"
    else
      out="$(claude -p "$prompt" --output-format text --strict-mcp-config 2>&1)"
    fi
    code=$?
    ;;
  codex)
    model="$(jq -r '.codexModel // ""' "$cfg" 2>/dev/null)"
    args=(exec --skip-git-repo-check --ephemeral --ignore-user-config --ignore-rules --sandbox read-only -C "$here" --color never)
    [ -n "$model" ] && args+=(-m "$model")
    args+=("$prompt")
    out="$(codex "${args[@]}" 2>&1)"
    code=$?
    ;;
  agy)
    model="$(jq -r '.agyModel // ""' "$cfg" 2>/dev/null)"
    args=(--print --print-timeout 2m)
    [ -n "$model" ] && args+=(--model "$model")
    args+=("$prompt")
    out="$(agy "${args[@]}" 2>&1)"
    code=$?
    ;;
esac

logline "$code" "$out"
tail -n 500 "$log" > "$log.tmp" && mv "$log.tmp" "$log"
exit "$code"
