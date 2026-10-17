# worker the Warmer task runs each cycle: one tiny claude ping.
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
Set-Location $PSScriptRoot

$log = Join-Path $PSScriptRoot 'warm.log'
$cfgPath = Join-Path $PSScriptRoot 'config.json'
$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

function HasProp($o, $n) { $null -ne $o.PSObject.Properties[$n] }

function ClaudeCommand {
  $p = Join-Path $env:APPDATA 'npm\claude.cmd'
  if (Test-Path $p) { return $p }
  $c = Get-Command claude -ErrorAction SilentlyContinue
  if ($c) {
    if ($c.Source) { return $c.Source }
    if ($c.Path) { return $c.Path }
    return $c.Name
  }
  $null
}

function TextOf($x) {
  if ($x -is [System.Management.Automation.ErrorRecord]) { return [string]$x.Exception.Message }
  [string]$x
}

function CaptureText($items) {
  $txt = @($items | ForEach-Object { TextOf $_ }) -join "`n"
  $txt = $txt -replace "$([char]27)\[[0-9;?]*[ -/]*[@-~]", ''
  $txt = ($txt -replace '\s+', ' ').Trim()
  if ([string]::IsNullOrWhiteSpace($txt)) { $txt = '(no output)' }
  if ($txt.Length -gt 220) { $txt = $txt.Substring(0, 220) }
  $txt
}

function WriteLog($code, $text) {
  "$ts  exit=$code  $text" | Add-Content -Encoding utf8 $log
}

try {
  $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json

  $cmd = ClaudeCommand
  if (-not $cmd) {
    WriteLog 127 'claude command not found'
    exit 127
  }

  $prompt = if ((HasProp $cfg 'prompt') -and $cfg.prompt) { [string]$cfg.prompt } else { 'Reply with only: ok' }
  # missing key -> haiku (same as the cli shows), explicit "" -> claude's own default
  $model  = if (HasProp $cfg 'model') { [string]$cfg.model } else { 'haiku' }
  $base   = if ((HasProp $cfg 'baseUrl') -and $cfg.baseUrl) { [string]$cfg.baseUrl } else { 'https://api.anthropic.com' }

  # hit the real subscription: official endpoint + oauth login, no api key, no proxy from user settings
  $env:ANTHROPIC_BASE_URL = $base
  Remove-Item Env:\ANTHROPIC_API_KEY    -ErrorAction SilentlyContinue
  Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue

  $a = @('-p', '--output-format', 'text', '--strict-mcp-config', '--no-session-persistence', '--setting-sources', 'project')
  if (-not [string]::IsNullOrWhiteSpace($model)) { $a += @('--model', $model) }
  # -- so a prompt starting with "-" isn't read as a flag
  $a += @('--', $prompt)
  $out = $null | & $cmd @a 2>&1
  $code = $LASTEXITCODE

  WriteLog $code (CaptureText $out)

  $lines = @(Get-Content $log -ErrorAction SilentlyContinue)
  if ($lines.Count -gt 500) { $lines[-500..-1] | Set-Content -Encoding utf8 $log }
  exit $code
} catch {
  WriteLog 1 (CaptureText @($_))
  exit 1
}
