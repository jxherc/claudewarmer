# warmer - keeps the claude 5h usage window cycling with a tiny scheduled ping.
# no param() block on purpose so subcommand args pass through as $args.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Root    = $PSScriptRoot
$CfgPath = Join-Path $Root 'config.json'
$Log     = Join-Path $Root 'warm.log'
$Worker  = Join-Path $Root 'warm-window.ps1'
$Version = '2.0.0'

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
  $c = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not (HasProp $c 'taskName')) { AddProp $c 'taskName' 'Warmer' }
  if (-not (HasProp $c 'model')) { AddProp $c 'model' 'haiku' }
  if (-not (HasProp $c 'baseUrl')) { AddProp $c 'baseUrl' 'https://api.anthropic.com' }
  $c
}
# no BOM, so the bash version's jq can read it too. drop old multi-tool keys while we're at it
function SaveCfg($c) {
  foreach ($k in @('tool', 'codexModel', 'agyModel')) { $c.PSObject.Properties.Remove($k) }
  [IO.File]::WriteAllText($CfgPath, ($c | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
}

function DisplayModel($c) {
  if ([string]::IsNullOrWhiteSpace([string]$c.model)) { 'default' } else { [string]$c.model }
}

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

# child process so the worker's env changes and Set-Location stay out of your shell
function RunWorker { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Worker | Out-Null }

# start via the scheduler unless it's missing or paused (a disabled task refuses to start)
function StartPing($t) {
  if ($t -and $t.State -ne 'Disabled') { Start-ScheduledTask -TaskName $t.TaskName; return }
  RunWorker
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
  throw "can't parse interval '$txt'. try: 5h1m | 5:01 | 301"
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

  # allow wake timers. best effort, a locked power plan shouldn't fail setup
  try {
    powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 2>$null | Out-Null
    powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_SLEEP RTCWAKE 1 2>$null | Out-Null
    powercfg /SETACTIVE SCHEME_CURRENT 2>$null | Out-Null
  } catch {}
}

function LogLines { @(Get-Content $Log -ErrorAction SilentlyContinue) | Where-Object { $_ -match 'exit=' } }

# true if a new log line showed up. compares the last line too since the log is trimmed at 500
function WaitForPing($beforeLast, $timeoutSec) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  do {
    Start-Sleep -Seconds 4
    $now = @(LogLines) | Select-Object -Last 1
    $t = TaskOf
    $running = $t -and ((Get-ScheduledTask -TaskName $t.TaskName | Get-ScheduledTaskInfo).LastTaskResult -eq 0x41301)
    if ($now -and $now -ne $beforeLast -and -not $running) { return $true }
  } until ((Get-Date) -gt $deadline)
  $false
}

function Cmd-Status {
  $c = Cfg
  $t = TaskOf
  head "Warmer"
  dim "  model      : $(DisplayModel $c)"
  dim "  endpoint   : $($c.baseUrl)"
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
  $before = @(LogLines) | Select-Object -Last 1
  if ($t -and $t.State -ne 'Disabled') { Write-Host "pinging via scheduler..." }
  else { warn "task not installed or paused - running worker directly" }
  StartPing $t
  if (-not (WaitForPing $before 300)) { bad "  no new log line after 5 min"; return }
  $last = @(LogLines) | Select-Object -Last 1
  if ($last -match '  exit=0  ') { ok "  $last" } else { bad "  $last" }
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
  $okc  = (@($lines | Where-Object { $_ -match '  exit=0  ' })).Count
  $fail = $lines.Count - $okc
  $rate = [math]::Round(100 * $okc / $lines.Count, 1)
  $first = ($lines | Select-Object -First 1) -replace '\s\s.*',''
  $last  = ($lines | Select-Object -Last 1)  -replace '\s\s.*',''
  Write-Host "  total : $($lines.Count)"
  ok        "  ok    : $okc  ($rate%)"
  if ($fail -gt 0) { bad "  fail  : $fail" } else { Write-Host "  fail  : 0" }
  dim       "  span  : $first  ->  $last"
  if ($fail -gt 0) {
    $lf = @($lines | Where-Object { $_ -notmatch '  exit=0  ' }) | Select-Object -Last 1
    bad "  last fail: $lf"
  }
}

function Cmd-Interval($parts) {
  if (-not $parts -or $parts.Count -eq 0) { $c = Cfg; Write-Host "current interval: $($c.intervalHours)h $($c.intervalMinutes)m"; return }
  $iv = ParseInterval $parts
  if ($iv.H -eq 0 -and $iv.M -eq 0) { throw "interval can't be zero" }
  $iv.H = [int]($iv.H + [math]::Floor($iv.M / 60)); $iv.M = $iv.M % 60
  $c = Cfg; $c.intervalHours = $iv.H; $c.intervalMinutes = $iv.M; SaveCfg $c
  if (TaskOf) { RegisterTask }
  ok "interval set to $($iv.H)h $($iv.M)m and task re-registered"
}

function Cmd-Set($parts) {
  if ($parts.Count -lt 2) { throw "usage: warmer set <model|prompt|baseUrl> <value...>" }
  $key = $parts[0].ToLower(); $val = ($parts[1..($parts.Count-1)] -join ' ')
  $c = Cfg
  switch ($key) {
    'model'   { PutProp $c 'model' $val }
    'prompt'  { PutProp $c 'prompt' $val }
    'baseurl' { PutProp $c 'baseUrl' $val }
    default   { throw "unknown key '$key'. valid: model | prompt | baseUrl" }
  }
  SaveCfg $c
  ok "set $key = $val"
  dim "(takes effect on the next ping)"
}

function Cmd-Config { head "config.json"; Get-Content $CfgPath -Raw }

function Cmd-Doctor {
  head "Warmer doctor"
  $fail = 0
  try {
    $c = Cfg
    ok "  [ok]  config.json valid (model=$(DisplayModel $c), every $($c.intervalHours)h $($c.intervalMinutes)m)"
  } catch {
    bad "  [!!]  config.json broken: $_"; $fail++
  }

  $cmd = ClaudeCommand
  if ($cmd) { ok "  [ok]  claude cli ($cmd)" } else { bad "  [!!]  claude cli missing"; $fail++ }

  $cred = Join-Path $HOME '.claude\.credentials.json'
  if (Test-Path $cred) {
    try { $j = Get-Content $cred -Raw | ConvertFrom-Json; if ($j.claudeAiOauth) { ok "  [ok]  claude oauth present" } else { warn "  [??]  credentials.json has no oauth block" } }
    catch { warn "  [??]  couldn't read credentials.json" }
  } else { bad "  [!!]  no ~/.claude/.credentials.json - run 'claude' once"; $fail++ }

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
  $before = @(LogLines) | Select-Object -Last 1
  StartPing $t
  $got = WaitForPing $before 300
  $last = @(LogLines) | Select-Object -Last 1
  if ($got -and $last -match '  exit=0  ') { ok "  [ok]  live ping -> $last" } else { bad "  [!!]  live ping failed -> $last"; $fail++ }

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
warmer - keeps the claude 5h usage window cycling with a tiny scheduled ping

usage
  warmer [command] [args]

info
  status            task state, last/next ping
  stats             success/fail counts and rate from the log
  logs [N]          show last N log lines (default 25)
  follow            live-tail the log
  config            print config.json
  doctor            full health check + a live test ping
  version

control
  ping              ping claude right now
  install           register the scheduled task
  uninstall         remove the scheduled task
  enable / disable  resume / pause without uninstalling
  restart           re-register after editing config
  setup             wire up global command + install task
  open              open the warmer folder

tuning
  interval <spec>   change cadence, e.g. warmer interval 5h1m | 5:01 | 301
  set model <m>     e.g. warmer set model haiku
  set prompt <txt>  change the ping text
  set baseUrl <url> override the api endpoint
"@ | Write-Host
}

$cmd = if ($args.Count -ge 1) { ([string]$args[0]).ToLower() } else { 'status' }
$rest = @(); if ($args.Count -gt 1) { $rest = @($args[1..($args.Count-1)]) }

try {
  switch ($cmd) {
    'status'    { Cmd-Status }
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

