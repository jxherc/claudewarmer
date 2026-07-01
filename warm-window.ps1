# worker the Warmer task runs each cycle.
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
Set-Location $PSScriptRoot

$log = Join-Path $PSScriptRoot 'warm.log'
$cfgPath = Join-Path $PSScriptRoot 'config.json'
$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$tools = @('claude', 'codex', 'agy')

function HasProp($o, $n) { $null -ne $o.PSObject.Properties[$n] }
function ToolCommand($tool) {
  switch ($tool) {
    'claude' {
      $p = Join-Path $env:APPDATA 'npm\claude.cmd'
      if (Test-Path $p) { return $p }
      $c = Get-Command claude -ErrorAction SilentlyContinue
    }
    'codex' {
      $p = Join-Path $env:APPDATA 'npm\codex.cmd'
      if (Test-Path $p) { return $p }
      $c = Get-Command codex -ErrorAction SilentlyContinue
    }
    'agy' {
      $c = Get-Command agy -ErrorAction SilentlyContinue
    }
  }
  if ($c) {
    if ($c.Source) { return $c.Source }
    if ($c.Path) { return $c.Path }
    return $c.Name
  }
  $null
}

function ModelFor($cfg, $tool) {
  switch ($tool) {
    'claude' { if (HasProp $cfg 'model') { return [string]$cfg.model } }
    'codex'  { if (HasProp $cfg 'codexModel') { return [string]$cfg.codexModel } }
    'agy'    { if (HasProp $cfg 'agyModel') { return [string]$cfg.agyModel } }
  }
  ''
}

function TextOf($x) {
  if ($x -is [System.Management.Automation.ErrorRecord]) { return [string]$x.Exception.Message }
  [string]$x
}

function CaptureText($items) {
  $txt = @($items | ForEach-Object { TextOf $_ }) -join "`n"
  $txt = $txt -replace "`e\[[0-9;?]*[ -/]*[@-~]", ''
  $txt = ($txt -replace '\s+', ' ').Trim()
  if ([string]::IsNullOrWhiteSpace($txt)) { $txt = '(no output)' }
  if ($txt.Length -gt 220) { $txt = $txt.Substring(0, 220) }
  $txt
}

function WriteLog($code, $tool, $text) {
  "$ts  tool=$tool  exit=$code  $text" | Add-Content -Encoding utf8 $log
}

try {
  $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
  $tool = if ((HasProp $cfg 'tool') -and $cfg.tool) { ([string]$cfg.tool).Trim().ToLower() } else { 'claude' }
  if ($tools -notcontains $tool) {
    WriteLog 2 $tool 'unsupported tool. valid: claude | codex | agy'
    exit 2
  }

  $cmd = ToolCommand $tool
  if (-not $cmd) {
    WriteLog 127 $tool "$tool command not found"
    exit 127
  }

  $prompt = if (HasProp $cfg 'prompt') { [string]$cfg.prompt } else { 'Reply with only: ok' }
  $model = ModelFor $cfg $tool

  if ($tool -eq 'claude') {
    if (HasProp $cfg 'baseUrl') { $env:ANTHROPIC_BASE_URL = $cfg.baseUrl }
    Remove-Item Env:\ANTHROPIC_API_KEY    -ErrorAction SilentlyContinue
    Remove-Item Env:\ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue

    $a = @('-p', $prompt, '--output-format', 'text', '--strict-mcp-config')
    if (-not [string]::IsNullOrWhiteSpace($model)) { $a += @('--model', $model) }
    $out = $null | & $cmd @a 2>&1
    $code = $LASTEXITCODE
  }
  elseif ($tool -eq 'codex') {
    $a = @('exec', '--skip-git-repo-check', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--sandbox', 'read-only', '-C', $PSScriptRoot, '--color', 'never')
    if (-not [string]::IsNullOrWhiteSpace($model)) { $a += @('-m', $model) }
    $a += @($prompt)
    $out = & $cmd @a 2>&1
    $code = $LASTEXITCODE
  }
  elseif ($tool -eq 'agy') {
    $a = @('--print', '--print-timeout', '2m')
    if (-not [string]::IsNullOrWhiteSpace($model)) { $a += @('--model', $model) }
    $a += @($prompt)
    $out = & $cmd @a 2>&1
    $code = $LASTEXITCODE
  }

  WriteLog $code $tool (CaptureText $out)

  $lines = @(Get-Content $log -ErrorAction SilentlyContinue)
  if ($lines.Count -gt 500) { $lines[-500..-1] | Set-Content -Encoding utf8 $log }
  exit $code
} catch {
  WriteLog 1 'unknown' (CaptureText @($_))
  exit 1
}

