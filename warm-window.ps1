# worker the WindowWarmer tasks run each cycle. one tiny ping -> a fresh usage window starts.
# takes a provider id (claude, codex, gemini, ...). defaults to claude so the old call still works.
param([string]$Provider = 'claude')

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}   # so proxy/chinese errors don't turn into mojibake in the log
Set-Location $PSScriptRoot
$log = Join-Path $PSScriptRoot 'warm.log'
$ts  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

function logline($code, $msg) {
  $msg = ($msg -replace '\s+', ' ').Trim()
  if ($msg.Length -gt 220) { $msg = $msg.Substring(0, 220) }
  "$ts  [$Provider]  exit=$code  $msg" | Add-Content -Encoding utf8 $log
}

$cfg = Get-Content (Join-Path $PSScriptRoot 'config.json') -Raw | ConvertFrom-Json
$p   = $cfg.providers.$Provider
if (-not $p) { logline 2 "unknown provider '$Provider'"; exit 2 }

# resolve the command. if it looks like a path (has a slash / drive), expand %VARS% and check it exists.
# otherwise trust it's on PATH and let the call fail loudly if it isn't.
$cmd = $p.cmd
if ($cmd -match '[\\/]') {
  $cmd = [Environment]::ExpandEnvironmentVariables($cmd)
  if (-not (Test-Path $cmd)) { logline 127 "command not found at $cmd"; exit 127 }
}

# build args: substitute {prompt} / {model}. if model is blank, drop {model} AND the flag right before it,
# so a "-m {model}" / "--model {model}" pair vanishes clean instead of passing an empty value.
$hasModel = -not [string]::IsNullOrWhiteSpace($p.model)
$argList = @()
foreach ($a in $p.args) {
  if ($a -eq '{model}') {
    if ($hasModel) { $argList += [string]$p.model }
    else { if ($argList.Count -gt 0) { $argList = $argList[0..($argList.Count-2)] } }  # pop the trailing flag
    continue
  }
  $argList += ($a -replace '\{prompt\}', $p.prompt) -replace '\{model\}', [string]$p.model
}

# some boxes route a cli through a 3rd-party proxy via the user env (e.g. claude -> cc-switch).
# provider config can force the right endpoint and ditch inherited keys so the ping hits the real account.
# (process exits right after, so no need to restore any of this)
if ($p.env) {
  foreach ($k in $p.env.PSObject.Properties.Name) { Set-Item -Path "Env:\$k" -Value $p.env.$k }
}
if ($p.clearEnv) {
  foreach ($k in $p.clearEnv) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue }
}

# $null piped in closes stdin right away so the cli doesn't sit there waiting on it
$resp = $null | & $cmd @argList 2>&1 | Out-String
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }   # some cmds don't set it on a clean run

logline $code $resp

# don't let the log grow forever
$lines = @(Get-Content $log -ErrorAction SilentlyContinue)
if ($lines.Count -gt 500) { $lines[-500..-1] | Set-Content -Encoding utf8 $log }

exit $code
