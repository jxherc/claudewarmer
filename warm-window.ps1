# worker the ClaudeWindowWarmer task runs each cycle. one tiny ping -> a fresh 5h window starts.
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}   # so proxy/chinese errors don't turn into mojibake in the log
Set-Location $PSScriptRoot
$log = Join-Path $PSScriptRoot 'warm.log'

$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

$cfg = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
$claude = Join-Path $env:APPDATA 'npm\claude.cmd'

if (-not (Test-Path $claude)) {
  "$ts  exit=127  claude.cmd not found at $claude" | Add-Content -Encoding utf8 $log
  exit 127
}

# this box routes claude through a 3rd-party proxy by default (cc-switch -> cn.meai.cloud).
# the 5h limit lives on the real subscription, so force the official endpoint + oauth login
# and ditch whatever proxy key the scheduled task inherited from the user env.
$env:ANTHROPIC_BASE_URL = $cfg.baseUrl
Remove-Item Env:\ANTHROPIC_API_KEY    -ErrorAction SilentlyContinue
Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue

# $null piped in closes stdin right away so the cli doesn't sit there waiting 3s for it
$resp = $null | & $claude -p $cfg.prompt --model $cfg.model --output-format text --strict-mcp-config 2>&1 | Out-String
$code = $LASTEXITCODE

$resp = ($resp -replace '\s+', ' ').Trim()
if ($resp.Length -gt 220) { $resp = $resp.Substring(0, 220) }
"$ts  exit=$code  $resp" | Add-Content -Encoding utf8 $log

# don't let the log grow forever
$lines = @(Get-Content $log -ErrorAction SilentlyContinue)
if ($lines.Count -gt 500) { $lines[-500..-1] | Set-Content -Encoding utf8 $log }

exit $code
