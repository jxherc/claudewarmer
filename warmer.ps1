# warmer - cli for the claude 5h window warmer.
# no param() block on purpose so subcommand args like bare numbers / words pass through clean as $args.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Root    = $PSScriptRoot
$CfgPath = Join-Path $Root 'config.json'
$Log     = Join-Path $Root 'warm.log'
$Worker  = Join-Path $Root 'warm-window.ps1'
$Claude  = Join-Path $env:APPDATA 'npm\claude.cmd'
$Version = '1.0.0'

# ---------- helpers ----------
function ok($m)   { Write-Host $m -ForegroundColor Green }
function bad($m)  { Write-Host $m -ForegroundColor Red }
function warn($m) { Write-Host $m -ForegroundColor Yellow }
function dim($m)  { Write-Host $m -ForegroundColor DarkGray }
function head($m) { Write-Host ""; Write-Host $m -ForegroundColor Cyan }

function Cfg      { Get-Content $CfgPath -Raw | ConvertFrom-Json }
function SaveCfg($c) { ($c | ConvertTo-Json) | Set-Content -Encoding utf8 $CfgPath }
function TaskOf   { Get-ScheduledTask -TaskName (Cfg).taskName -ErrorAction SilentlyContinue }

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

# turns "5h2m", "5:02", "302" (mins) or "5 2" into @{H;M}
function ParseInterval($parts) {
  $txt = ($parts -join ' ').Trim()
  if ($txt -match '^(\d+)\s*[hH]\s*(\d+)\s*[mM]?$')      { return @{ H=[int]$Matches[1]; M=[int]$Matches[2] } }
  if ($txt -match '^(\d+)\s*[hH]$')                       { return @{ H=[int]$Matches[1]; M=0 } }
  if ($txt -match '^(\d+)\s*:\s*(\d+)$')                  { return @{ H=[int]$Matches[1]; M=[int]$Matches[2] } }
  if ($txt -match '^(\d+)\s+(\d+)$')                      { return @{ H=[int]$Matches[1]; M=[int]$Matches[2] } }
  if ($txt -match '^(\d+)\s*[mM]?$')                      { $t=[int]$Matches[1]; return @{ H=[math]::Floor($t/60); M=$t%60 } }
  throw "can't parse interval '$txt'. try: 5h2m  |  5:02  |  302  (minutes)"
}

function RegisterTask {
  $c = Cfg
  $name = $c.taskName
  $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Worker`""
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
               -RepetitionInterval (New-TimeSpan -Hours $c.intervalHours -Minutes $c.intervalMinutes) `
               -RepetitionDuration (New-TimeSpan -Days 3650)   # MaxValue overflows the task xml, 10y is plenty
  $settings = New-ScheduledTaskSettingsSet -WakeToRun -StartWhenAvailable `
               -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

  Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
  Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Principal $principal | Out-Null

  # -WakeToRun is a no-op unless wake timers are allowed, so flip them on (best effort)
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

# ---------- subcommands ----------
function Cmd-Status {
  $c = Cfg
  $t = TaskOf
  head "Claude Window Warmer"
  if (-not $t) { bad "  task NOT installed   ->  run: warmer install"; return }
  $i = $t | Get-ScheduledTaskInfo
  $state = $t.State
  if ($state -eq 'Ready') { ok    "  state      : $state" }
  elseif ($state -eq 'Disabled') { warn "  state      : $state (paused -> warmer enable)" }
  else { warn "  state      : $state" }
  if ($i.LastTaskResult -eq 0x41303 -or $i.LastRunTime.Year -lt 2000) {
    dim "  last run   : not yet (since last re-register)"
  } else {
    $res = "0x{0:X}" -f $i.LastTaskResult
    $lastLine = "  last run   : $($i.LastRunTime)  (result $res)"
    if ($i.LastTaskResult -eq 0) { ok $lastLine } else { bad $lastLine }
  }
  Write-Host  "  next ping  : $($i.NextRunTime)  ($(HumanSpan $i.NextRunTime))"
  dim "  every      : $($c.intervalHours)h $($c.intervalMinutes)m   model=$($c.model)   -> $($c.baseUrl)"
  $last = @(LogLines) | Select-Object -Last 1
  if ($last) { dim "  last log   : $last" }
}

function Cmd-Ping {
  $t = TaskOf
  $before = (@(LogLines)).Count
  if ($t) { Write-Host "pinging via scheduler..."; Start-ScheduledTask -TaskName $t.TaskName }
  else    { warn "task not installed - running worker directly"; & $Worker | Out-Null }
  WaitForPing $before 150
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

function Cmd-Set($parts) {
  if ($parts.Count -lt 2) { throw "usage: warmer set <model|prompt|baseUrl> <value...>" }
  $key = $parts[0]; $val = ($parts[1..($parts.Count-1)] -join ' ')
  $c = Cfg
  switch ($key.ToLower()) {
    'model'   { $c.model = $val }
    'prompt'  { $c.prompt = $val }
    'baseurl' { $c.baseUrl = $val }
    default   { throw "unknown key '$key'. valid: model | prompt | baseUrl" }
  }
  SaveCfg $c
  ok "set $key = $val"
  dim "(takes effect on the next ping - no reinstall needed)"
}

function Cmd-Config { head "config.json"; Get-Content $CfgPath -Raw }

function Cmd-Doctor {
  head "Warmer doctor"
  $fail = 0
  # claude cli
  if (Test-Path $Claude) { ok "  [ok]  claude cli  ($Claude)" } else { bad "  [!!]  claude cli missing at $Claude"; $fail++ }
  # config
  try { $c = Cfg; ok "  [ok]  config.json valid (every $($c.intervalHours)h $($c.intervalMinutes)m, model=$($c.model))" }
  catch { bad "  [!!]  config.json broken: $_"; $fail++ }
  # oauth creds
  $cred = Join-Path $HOME '.claude\.credentials.json'
  if (Test-Path $cred) {
    try { $j = Get-Content $cred -Raw | ConvertFrom-Json; if ($j.claudeAiOauth) { ok "  [ok]  subscription oauth present" } else { warn "  [??]  credentials.json has no oauth block" } }
    catch { warn "  [??]  couldn't read credentials.json" }
  } else { bad "  [!!]  no ~/.claude/.credentials.json - run 'claude' once to log in"; $fail++ }
  # task
  $t = TaskOf
  if ($t) {
    $i = $t | Get-ScheduledTaskInfo
    ok "  [ok]  task registered (state=$($t.State), next $($i.NextRunTime))"
    if (-not $t.Settings.WakeToRun) { warn "  [??]  WakeToRun is off - pings may skip while asleep" }
  } else { bad "  [!!]  task not registered - run: warmer install"; $fail++ }
  # global command wiring
  $onPath = ([Environment]::GetEnvironmentVariable('Path','User')) -like "*$Root*"
  if ($onPath) { ok "  [ok]  folder on user PATH (warmer.cmd works in cmd)" } else { warn "  [??]  folder not on PATH - run warmer setup" }
  $prof = $PROFILE.CurrentUserAllHosts
  if ((Test-Path $prof) -and ((Get-Content $prof -Raw -ErrorAction SilentlyContinue) -match 'function warmer')) { ok "  [ok]  profile 'warmer' function installed" } else { warn "  [??]  profile function missing - run warmer setup" }
  # live ping
  Write-Host "  ...running a live test ping..." -ForegroundColor DarkGray
  $before = (@(LogLines)).Count
  if ($t) { Start-ScheduledTask -TaskName $t.TaskName } else { & $Worker | Out-Null }
  WaitForPing $before 150
  $last = @(LogLines) | Select-Object -Last 1
  if ($last -match 'exit=0') { ok "  [ok]  live ping -> $last" } else { bad "  [!!]  live ping failed -> $last"; $fail++ }

  Write-Host ""
  if ($fail -eq 0) { ok "all good." } else { bad "$fail problem(s) found." }
}

function Cmd-Setup {
  head "Setting up the 'warmer' global command"
  # 1. profile function (powershell, all hosts)
  $prof = $PROFILE.CurrentUserAllHosts
  if (-not (Test-Path $prof)) { New-Item -ItemType File -Path $prof -Force | Out-Null }
  $cur = [string](Get-Content $prof -Raw -ErrorAction SilentlyContinue)   # cast so an empty profile ($null) still adds
  if ($cur -notmatch 'function warmer') {
    Add-Content -Path $prof -Value "`nfunction warmer { & `"$Root\warmer.ps1`" @args }"
    ok "  added 'warmer' function to $prof"
  } else { dim "  profile function already present" }
  # 2. folder on user PATH (for cmd / non-profile shells via warmer.cmd)
  $up = [Environment]::GetEnvironmentVariable('Path','User')
  if ($up -notlike "*$Root*") {
    [Environment]::SetEnvironmentVariable('Path', ($up.TrimEnd(';') + ";$Root"), 'User')
    ok "  added $Root to user PATH"
  } else { dim "  folder already on PATH" }
  # 3. install the task
  RegisterTask
  ok "  scheduled task registered"
  Write-Host ""
  warn "open a NEW terminal, then:  warmer status"
}

function Cmd-Install   { RegisterTask; $i = TaskOf | Get-ScheduledTaskInfo; ok "installed - next ping $($i.NextRunTime)" }
function Cmd-Uninstall { if (TaskOf) { Unregister-ScheduledTask -TaskName (Cfg).taskName -Confirm:$false; ok "task removed" } else { warn "task wasn't installed" } }
function Cmd-Enable    { Enable-ScheduledTask  -TaskName (Cfg).taskName | Out-Null; ok "enabled" }
function Cmd-Disable   { Disable-ScheduledTask -TaskName (Cfg).taskName | Out-Null; warn "paused (warmer enable to resume)" }
function Cmd-Restart   { RegisterTask; ok "re-registered" }
function Cmd-Open      { Invoke-Item $Root }
function Cmd-Version   { Write-Host "warmer $Version" }

function Cmd-Help {
@"
warmer - keeps your Claude 5-hour window always freshly cycling

USAGE
  warmer [command] [args]

INFO
  status            task state, last/next ping, countdown   (default)
  stats             success/fail counts and rate from the log
  logs [N]          show last N log lines (default 25)
  follow            live-tail the log
  config            print config.json
  doctor            full health check + a live test ping
  version

CONTROL
  ping              fire a ping right now
  install           register the scheduled task
  uninstall         remove it
  enable / disable  resume / pause without uninstalling
  restart           re-register (after editing config by hand)
  setup             wire up the global 'warmer' command + install task
  open              open the warmer folder

TUNING
  interval <spec>   change cadence, e.g.  warmer interval 5h2m | 5:02 | 302
  set model <m>     e.g. warmer set model sonnet
  set prompt <txt>  change the ping text
  set baseUrl <url> override the api endpoint
"@ | Write-Host
}

# ---------- dispatch ----------
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
