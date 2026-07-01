# warmer - keeps one selected cli warm.
# no param() block on purpose so subcommand args pass through as $args.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Root    = $PSScriptRoot
$CfgPath = Join-Path $Root 'config.json'
$Log     = Join-Path $Root 'warm.log'
$Worker  = Join-Path $Root 'warm-window.ps1'
$Version = '1.1.0'
$Tools   = @('claude', 'codex', 'agy')

function ok($m)   { Write-Host $m -ForegroundColor Green }
function bad($m)  { Write-Host $m -ForegroundColor Red }
function warn($m) { Write-Host $m -ForegroundColor Yellow }
function dim($m)  { Write-Host $m -ForegroundColor DarkGray }
function head($m) { Write-Host ""; Write-Host $m -ForegroundColor Cyan }

function HasProp($o, $n) { $null -ne $o.PSObject.Properties[$n] }
function AddProp($o, $n, $v) { $o | Add-Member -NotePropertyName $n -NotePropertyValue $v }
function PutProp($o, $n, $v) {
  if (HasProp $o $n) { $o.$n = $v } else { AddProp $o $n $v }
}

function Cfg {
  $c = Get-Content $CfgPath -Raw | ConvertFrom-Json
  if (-not (HasProp $c 'taskName')) { AddProp $c 'taskName' 'Warmer' }
  if (-not (HasProp $c 'tool')) { AddProp $c 'tool' 'claude' }
  if (-not (HasProp $c 'model')) { AddProp $c 'model' 'haiku' }
  if (-not (HasProp $c 'codexModel')) { AddProp $c 'codexModel' '' }
  if (-not (HasProp $c 'agyModel')) { AddProp $c 'agyModel' '' }
  $c
}
function SaveCfg($c) { ($c | ConvertTo-Json -Depth 6) | Set-Content -Encoding utf8 $CfgPath }

function CleanTool($tool) {
  $t = ([string]$tool).Trim().ToLower()
  if ($Tools -notcontains $t) { throw "unknown tool '$tool'. valid: claude | codex | agy" }
  $t
}
function CurrentTool($c) { CleanTool $c.tool }

function ModelFor($c, $tool) {
  switch ($tool) {
    'claude' { return [string]$c.model }
    'codex'  { return [string]$c.codexModel }
    'agy'    { return [string]$c.agyModel }
  }
}
function SetModelFor($c, $tool, $model) {
  switch ($tool) {
    'claude' { PutProp $c 'model' $model }
    'codex'  { PutProp $c 'codexModel' $model }
    'agy'    { PutProp $c 'agyModel' $model }
  }
}
function DisplayModel($c, $tool) {
  $m = ModelFor $c $tool
  if ([string]::IsNullOrWhiteSpace($m)) { 'default' } else { $m }
}

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

function TaskOf { Get-ScheduledTask -TaskName (Cfg).taskName -ErrorAction SilentlyContinue }

function HumanSpan($ts) {
  if ($ts -eq $null) { return 'n/a' }
  $d = $ts - (Get-Date)
  $neg = $d.TotalSeconds -lt 0
  $d = [TimeSpan]::FromSeconds([math]::Abs($d.TotalSeconds))
  $s = ""
  if ($d.Days -gt 0)  { $s += "$($d.Days)d " }
  if ($d.Hours -gt 0) { $s += "$($d.Hours)h " }
  $s += "$($d.Minutes)m"
  if ($neg) { "$s ago" } else { "in $s" }
}

function ParseInterval($parts) {
  $txt = ($parts -join ' ').Trim()
  if ($txt -match '^(\d+)\s*[hH]\s*(\d+)\s*[mM]?$') { return @{ H=[int]$Matches[1]; M=[int]$Matches[2] } }
  if ($txt -match '^(\d+)\s*[hH]$')                  { return @{ H=[int]$Matches[1]; M=0 } }
  if ($txt -match '^(\d+)\s*:\s*(\d+)$')             { return @{ H=[int]$Matches[1]; M=[int]$Matches[2] } }
  if ($txt -match '^(\d+)\s+(\d+)$')                 { return @{ H=[int]$Matches[1]; M=[int]$Matches[2] } }
  if ($txt -match '^(\d+)\s*[mM]?$')                 { $t=[int]$Matches[1]; return @{ H=[math]::Floor($t/60); M=$t%60 } }
  throw "can't parse interval '$txt'. try: 5h2m | 5:02 | 302"
}

function RegisterTask {
  $c = Cfg
  $name = $c.taskName

  $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Worker`""
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
               -RepetitionInterval (New-TimeSpan -Hours $c.intervalHours -Minutes $c.intervalMinutes) `
               -RepetitionDuration (New-TimeSpan -Days 3650)
  $settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable `
               -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

  Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
  Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null

  powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 2>$null | Out-Null
  powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 2>$null | Out-Null
  powercfg /SETACTIVE SCHEME_CURRENT 2>$null | Out-Null
}

function LogLines { @(Get-Content $Log -ErrorAction SilentlyContinue) | Where-Object { $_ -match 'exit=' } }

function WaitForPing($beforeCount, $timeoutSec) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  do {
    Start-Sleep -Seconds 4
    $now = (@(LogLines)).Count
    $t = TaskOf
    $running = $t -and ((Get-ScheduledTask -TaskName $t.TaskName | Get-ScheduledTaskInfo).LastTaskResult -eq 0x41301)
  } until (($now -gt $beforeCount -and -not $running) -or (Get-Date) -gt $deadline)
}

function Cmd-Status {
  $c = Cfg
  $tool = CurrentTool $c
  $t = TaskOf
  head "Warmer"
  dim "  tool       : $tool   model=$(DisplayModel $c $tool)"
  if ($tool -eq 'claude') { dim "  endpoint   : $($c.baseUrl)" }
  if (-not $t) { bad "  task       : not installed -> run: warmer install"; return }
  $i = $t | Get-ScheduledTaskInfo
  $state = $t.State
  if ($state -eq 'Ready') { ok "  state      : $state" }
  elseif ($state -eq 'Disabled') { warn "  state      : $state (paused -> warmer enable)" }
  else { warn "  state      : $state" }
  if ($i.LastTaskResult -eq 0x41303 -or $i.LastRunTime.Year -lt 2000) {
    dim "  last run   : not yet"
  } else {
    $res = "0x{0:X}" -f $i.LastTaskResult
    $lastLine = "  last run   : $($i.LastRunTime)  (result $res)"
    if ($i.LastTaskResult -eq 0) { ok $lastLine } else { bad $lastLine }
  }
  Write-Host  "  next ping  : $($i.NextRunTime)  ($(HumanSpan $i.NextRunTime))"
  dim "  every      : $($c.intervalHours)h $($c.intervalMinutes)m"
  $last = @(LogLines) | Select-Object -Last 1
  if ($last) { dim "  last log   : $last" }
}

function Cmd-Ping {
  $t = TaskOf
  $before = (@(LogLines)).Count
  if ($t) { Write-Host "pinging via scheduler..."; Start-ScheduledTask -TaskName $t.TaskName }
  else    { warn "task not installed - running worker directly"; & $Worker | Out-Null }
  WaitForPing $before 300
  $last = @(LogLines) | Select-Object -Last 1
  if ($last -match 'exit=0') { ok "  $last" } else { bad "  $last" }
}

function Cmd-Logs($n) {
  if (-not $n) { $n = 25 }
  if (-not (Test-Path $Log)) { warn "no log yet"; return }
  Get-Content $Log -Tail ([int]$n)
}

function Cmd-Follow {
  if (-not (Test-Path $Log)) { warn "no log yet - waiting for first ping..."; New-Item -ItemType File $Log | Out-Null }
  Write-Host "tailing warm.log (ctrl-c to stop)..." -ForegroundColor DarkGray
  Get-Content $Log -Tail 10 -Wait
}

function Cmd-Stats {
  $lines = @(LogLines)
  head "Ping stats"
  if ($lines.Count -eq 0) { warn "  no pings logged yet"; return }
  $okc  = (@($lines | Where-Object { $_ -match 'exit=0' })).Count
  $fail = $lines.Count - $okc
  $rate = [math]::Round(100 * $okc / $lines.Count, 1)
  $first = ($lines | Select-Object -First 1) -replace '\s\s.*',''
  $last  = ($lines | Select-Object -Last 1)  -replace '\s\s.*',''
  Write-Host "  total : $($lines.Count)"
  ok        "  ok    : $okc  ($rate%)"
  if ($fail -gt 0) { bad "  fail  : $fail" } else { Write-Host "  fail  : 0" }
  dim       "  span  : $first  ->  $last"
  if ($fail -gt 0) {
    $lf = @($lines | Where-Object { $_ -notmatch 'exit=0' }) | Select-Object -Last 1
    bad "  last fail: $lf"
  }
}

function Cmd-Interval($parts) {
  if (-not $parts -or $parts.Count -eq 0) { $c = Cfg; Write-Host "current interval: $($c.intervalHours)h $($c.intervalMinutes)m"; return }
  $iv = ParseInterval $parts
  if ($iv.H -eq 0 -and $iv.M -eq 0) { throw "interval can't be zero" }
  $c = Cfg; $c.intervalHours = $iv.H; $c.intervalMinutes = $iv.M; SaveCfg $c
  if (TaskOf) { RegisterTask }
  ok "interval set to $($iv.H)h $($iv.M)m and task re-registered"
}

function Cmd-Use($parts) {
  if (-not $parts -or $parts.Count -lt 1) { throw "usage: warmer use <claude|codex|agy>" }
  $tool = CleanTool $parts[0]
  if (-not (ToolCommand $tool)) { throw "$tool is not installed or not on PATH" }
  $c = Cfg
  PutProp $c 'tool' $tool
  SaveCfg $c
  ok "using $tool"
  dim "run warmer ping to test it now"
}

function Cmd-Set($parts) {
  if ($parts.Count -lt 2) { throw "usage: warmer set <tool|model|prompt|baseUrl> <value...>" }
  $key = $parts[0].ToLower(); $val = ($parts[1..($parts.Count-1)] -join ' ')
  $c = Cfg
  switch ($key) {
    'tool'    { PutProp $c 'tool' (CleanTool $val) }
    'model'   { SetModelFor $c (CurrentTool $c) $val }
    'prompt'  { PutProp $c 'prompt' $val }
    'baseurl' { PutProp $c 'baseUrl' $val }
    default   { throw "unknown key '$key'. valid: tool | model | prompt | baseUrl" }
  }
  SaveCfg $c
  ok "set $key = $val"
  dim "(takes effect on the next ping)"
}

function Cmd-Config { head "config.json"; Get-Content $CfgPath -Raw }

function Cmd-Tools {
  $c = Cfg
  $cur = CurrentTool $c
  head "Tools"
  foreach ($t in $Tools) {
    $cmd = ToolCommand $t
    $mark = if ($t -eq $cur) { '*' } else { ' ' }
    if ($cmd) { ok "  $mark $t  ok  $cmd" } else { bad "  $mark $t  missing" }
  }
}

function Cmd-Doctor {
  head "Warmer doctor"
  $fail = 0
  try {
    $c = Cfg
    $tool = CurrentTool $c
    ok "  [ok]  config.json valid (tool=$tool, every $($c.intervalHours)h $($c.intervalMinutes)m)"
  } catch {
    bad "  [!!]  config.json broken: $_"; $fail++; $tool = 'claude'
  }

  foreach ($t in $Tools) {
    $cmd = ToolCommand $t
    if ($cmd) { ok "  [ok]  $t cli ($cmd)" } else { bad "  [!!]  $t cli missing"; if ($t -eq $tool) { $fail++ } }
  }

  if ($tool -eq 'claude') {
    $cred = Join-Path $HOME '.claude\.credentials.json'
    if (Test-Path $cred) {
      try { $j = Get-Content $cred -Raw | ConvertFrom-Json; if ($j.claudeAiOauth) { ok "  [ok]  claude oauth present" } else { warn "  [??]  credentials.json has no oauth block" } }
      catch { warn "  [??]  couldn't read credentials.json" }
    } else { bad "  [!!]  no ~/.claude/.credentials.json - run 'claude' once"; $fail++ }
  }

  $t = TaskOf
  if ($t) {
    $i = $t | Get-ScheduledTaskInfo
    ok "  [ok]  task registered (state=$($t.State), next $($i.NextRunTime))"
    if (-not $t.Settings.WakeToRun) { warn "  [??]  WakeToRun is off - pings may skip while asleep" }
  } else { bad "  [!!]  task not registered - run: warmer install"; $fail++ }

  $onPath = ([Environment]::GetEnvironmentVariable('Path','User') -split ';') -contains $Root
  if ($onPath) { ok "  [ok]  folder on user PATH" } else { warn "  [??]  folder not on PATH - run warmer setup" }
  $prof = $PROFILE.CurrentUserAllHosts
  $needle = [regex]::Escape("$Root\warmer.ps1")
  if ((Test-Path $prof) -and ((Get-Content $prof -Raw -ErrorAction SilentlyContinue) -match $needle)) { ok "  [ok]  profile warmer function points here" } else { warn "  [??]  profile function missing/stale - run warmer setup" }

  Write-Host "  ...running a live test ping..." -ForegroundColor DarkGray
  $before = (@(LogLines)).Count
  if ($t) { Start-ScheduledTask -TaskName $t.TaskName } else { & $Worker | Out-Null }
  WaitForPing $before 300
  $last = @(LogLines) | Select-Object -Last 1
  if ($last -match 'exit=0') { ok "  [ok]  live ping -> $last" } else { bad "  [!!]  live ping failed -> $last"; $fail++ }

  Write-Host ""
  if ($fail -eq 0) { ok "all good." } else { bad "$fail problem(s) found." }
}

function Cmd-Setup {
  head "Setting up warmer"
  $line = "function warmer { & `"$Root\warmer.ps1`" @args }"
  $profiles = @(
    $PROFILE.CurrentUserAllHosts,
    (Join-Path $HOME 'Documents\PowerShell\profile.ps1'),
    (Join-Path $HOME 'Documents\WindowsPowerShell\profile.ps1')
  ) | Where-Object { $_ } | Select-Object -Unique

  foreach ($prof in $profiles) {
    $dir = Split-Path -Parent $prof
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $prof)) { New-Item -ItemType File -Path $prof -Force | Out-Null }
    $cur = [string](Get-Content $prof -Raw -ErrorAction SilentlyContinue)
    if ($cur -match '(?m)^function\s+warmer\s*\{.*\}\s*$') {
      if ($cur -notmatch [regex]::Escape("$Root\warmer.ps1")) {
        $cur = [regex]::Replace($cur, '(?m)^function\s+warmer\s*\{.*\}\s*$', $line)
        Set-Content -Path $prof -Value $cur -Encoding utf8
        ok "  updated warmer function in $prof"
      } else { dim "  profile function already points here: $prof" }
    } else {
      Add-Content -Path $prof -Value "`n$line"
      ok "  added warmer function to $prof"
    }
  }

  $up = [Environment]::GetEnvironmentVariable('Path','User')
  $parts = @($up -split ';' | Where-Object { $_ -and $_ -ne $Root })
  $parts += $Root
  [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User')
  ok "  user PATH points at $Root"

  RegisterTask
  ok "  scheduled task registered"
  Write-Host ""
  warn "open a new terminal, then: warmer status"
}

function Cmd-Install   { RegisterTask; $i = TaskOf | Get-ScheduledTaskInfo; ok "installed - next ping $($i.NextRunTime)" }
function Cmd-Uninstall {
  $name = (Cfg).taskName
  if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $name -Confirm:$false
    ok "removed task $name"
  } else { warn "task wasn't installed" }
}
function Cmd-Enable    { Enable-ScheduledTask  -TaskName (Cfg).taskName | Out-Null; ok "enabled" }
function Cmd-Disable   { Disable-ScheduledTask -TaskName (Cfg).taskName | Out-Null; warn "paused (warmer enable to resume)" }
function Cmd-Restart   { RegisterTask; ok "re-registered" }
function Cmd-Open      { Invoke-Item $Root }
function Cmd-Version   { Write-Host "warmer $Version" }

function Cmd-Help {
@"
warmer - keeps claude, codex, or agy warmed with a tiny scheduled ping

usage
  warmer [command] [args]

info
  status            task state, selected tool, last/next ping
  tools             show claude/codex/agy install status
  stats             success/fail counts and rate from the log
  logs [N]          show last N log lines (default 25)
  follow            live-tail the log
  config            print config.json
  doctor            full health check + a live test ping
  version

control
  use <tool>        switch tool: claude | codex | agy
  ping              fire a ping right now
  install           register the scheduled task
  uninstall         remove the scheduled task
  enable / disable  resume / pause without uninstalling
  restart           re-register after editing config
  setup             wire up global command + install task
  open              open the warmer folder

tuning
  interval <spec>   change cadence, e.g. warmer interval 5h2m | 5:02 | 302
  set model <m>     set model for the selected tool
  set prompt <txt>  change the ping text
  set baseUrl <url> override claude's api endpoint
"@ | Write-Host
}

$cmd = if ($args.Count -ge 1) { ([string]$args[0]).ToLower() } else { 'status' }
$rest = @(); if ($args.Count -gt 1) { $rest = @($args[1..($args.Count-1)]) }

try {
  switch ($cmd) {
    'status'    { Cmd-Status }
    'tools'     { Cmd-Tools }
    'stats'     { Cmd-Stats }
    'history'   { Cmd-Stats }
    'logs'      { Cmd-Logs $rest[0] }
    'log'       { Cmd-Logs $rest[0] }
    'follow'    { Cmd-Follow }
    'tail'      { Cmd-Follow }
    'config'    { Cmd-Config }
    'doctor'    { Cmd-Doctor }
    'test'      { Cmd-Doctor }
    'ping'      { Cmd-Ping }
    'now'       { Cmd-Ping }
    'use'       { Cmd-Use $rest }
    'switch'    { Cmd-Use $rest }
    'install'   { Cmd-Install }
    'uninstall' { Cmd-Uninstall }
    'remove'    { Cmd-Uninstall }
    'enable'    { Cmd-Enable }
    'disable'   { Cmd-Disable }
    'pause'     { Cmd-Disable }
    'restart'   { Cmd-Restart }
    'setup'     { Cmd-Setup }
    'open'      { Cmd-Open }
    'interval'  { Cmd-Interval $rest }
    'set'       { Cmd-Set $rest }
    'version'   { Cmd-Version }
    '-v'        { Cmd-Version }
    'help'      { Cmd-Help }
    '-h'        { Cmd-Help }
    '--help'    { Cmd-Help }
    default     { bad "unknown command: $cmd"; Cmd-Help; exit 1 }
  }
} catch {
  bad "error: $($_.Exception.Message)"
  exit 1
}

