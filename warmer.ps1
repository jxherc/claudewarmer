# warmer - cli for the AI-cli window warmer. keeps each provider's rolling usage window fresh.
# no param() block on purpose so subcommand args (bare ids/numbers/words) pass through clean as $args.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$Root    = $PSScriptRoot
$CfgPath = Join-Path $Root 'config.json'
$Log     = Join-Path $Root 'warm.log'
$Worker  = Join-Path $Root 'warm-window.ps1'
$Version = '2.0.0'

# ---------- helpers ----------
function ok($m)   { Write-Host $m -ForegroundColor Green }
function bad($m)  { Write-Host $m -ForegroundColor Red }
function warn($m) { Write-Host $m -ForegroundColor Yellow }
function dim($m)  { Write-Host $m -ForegroundColor DarkGray }
function head($m) { Write-Host ""; Write-Host $m -ForegroundColor Cyan }

function Cfg      { Get-Content $CfgPath -Raw | ConvertFrom-Json }
function SaveCfg($c) { ($c | ConvertTo-Json -Depth 10) | Set-Content -Encoding utf8 $CfgPath }

function ProvIds  { @((Cfg).providers.PSObject.Properties.Name) }
function Prov($id) { (Cfg).providers.$id }
function EnabledIds { @((Cfg).providers.PSObject.Properties | Where-Object { $_.Value.enabled } | ForEach-Object { $_.Name }) }
function TaskName($id) { "$((Cfg).taskPrefix)-$id" }
function TaskOf($id)   { Get-ScheduledTask -TaskName (TaskName $id) -ErrorAction SilentlyContinue }

function ValidateProvider($id) {
  if (-not ((ProvIds) -contains $id)) { throw "unknown provider '$id'. known: $((ProvIds) -join ', ')" }
}

# is the provider's cli actually installed? path-like -> Test-Path, bare name -> look on PATH
function Detect($id) {
  $cmd = (Prov $id).cmd
  if ($cmd -match '[\\/]') { return (Test-Path ([Environment]::ExpandEnvironmentVariables($cmd))) }
  [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

# turn a rest-arg into a set of provider ids.
#   mode 'enabled' : no arg -> all enabled,  'all' -> every provider,  id -> [id]
#   mode 'all'     : no arg -> every provider,                         id -> [id]
#   mode 'require' : no arg -> error (must name one or 'all')
function ResolveIds($rest, $mode) {
  $arg = $rest[0]
  if (-not $arg) {
    switch ($mode) {
      'enabled' { return @(EnabledIds) }
      'all'     { return @(ProvIds) }
      'require' { throw "which provider? give an id or 'all'   (see: warmer list)" }
    }
  }
  if ($arg -eq 'all') { return @(ProvIds) }
  ValidateProvider $arg
  @($arg)
}

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

# "5h2m", "5:02", "302" (mins) or "5 2" -> @{H;M}
function ParseInterval($parts) {
  $txt = ($parts -join ' ').Trim()
  if ($txt -match '^(\d+)\s*[hH]\s*(\d+)\s*[mM]?$')      { return @{ H=[int]$Matches[1]; M=[int]$Matches[2] } }
  if ($txt -match '^(\d+)\s*[hH]$')                       { return @{ H=[int]$Matches[1]; M=0 } }
  if ($txt -match '^(\d+)\s*:\s*(\d+)$')                  { return @{ H=[int]$Matches[1]; M=[int]$Matches[2] } }
  if ($txt -match '^(\d+)\s+(\d+)$')                      { return @{ H=[int]$Matches[1]; M=[int]$Matches[2] } }
  if ($txt -match '^(\d+)\s*[mM]?$')                      { $t=[int]$Matches[1]; return @{ H=[math]::Floor($t/60); M=$t%60 } }
  throw "can't parse interval '$txt'. try: 5h2m  |  5:02  |  302  (minutes)"
}

function Remove-LegacyTask {
  if (Get-ScheduledTask -TaskName 'ClaudeWindowWarmer' -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName 'ClaudeWindowWarmer' -Confirm:$false -ErrorAction SilentlyContinue
    dim "  removed legacy task ClaudeWindowWarmer"
  }
}

function RegisterTask($id) {
  $p = Prov $id
  if ($p.intervalHours -eq 0 -and $p.intervalMinutes -eq 0) { throw "[$id] interval is zero - set one first" }
  $name = TaskName $id
  $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Worker`" -Provider $id"
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
               -RepetitionInterval (New-TimeSpan -Hours $p.intervalHours -Minutes $p.intervalMinutes) `
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

# log lines (only real ping lines). pass an id to filter to one provider.
function LogLines($id) {
  $all = @(Get-Content $Log -ErrorAction SilentlyContinue) | Where-Object { $_ -match 'exit=' }
  if ($id) { $all = $all | Where-Object { $_ -match "\[$id\]" } }
  @($all)
}

function WaitForPing($id, $beforeCount, $timeoutSec) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  do {
    Start-Sleep -Seconds 4
    $now = (LogLines $id).Count
    $t = TaskOf $id
    $running = $t -and (($t | Get-ScheduledTaskInfo).LastTaskResult -eq 0x41301)
  } until (($now -gt $beforeCount -and -not $running) -or (Get-Date) -gt $deadline)
}

# ---------- subcommands ----------
function Show-Detail($id) {
  $p = Prov $id
  $t = TaskOf $id
  head "Window Warmer - $($p.label) [$id]"
  Write-Host "  enabled    : $(if ($p.enabled) {'yes'} else {'no'})"
  dim       "  every      : $($p.intervalHours)h $($p.intervalMinutes)m   model=$($p.model)   cmd=$($p.cmd)"
  if (-not $t) { bad "  task NOT installed   ->  warmer install $id"; return }
  $i = $t | Get-ScheduledTaskInfo
  $state = $t.State
  if ($state -eq 'Ready') { ok "  state      : $state" }
  elseif ($state -eq 'Disabled') { warn "  state      : $state (paused -> warmer enable $id)" }
  else { warn "  state      : $state" }
  if ($i.LastTaskResult -eq 0x41303 -or $i.LastRunTime.Year -lt 2000) {
    dim "  last run   : not yet (since last re-register)"
  } else {
    $res = "0x{0:X}" -f $i.LastTaskResult
    $lastLine = "  last run   : $($i.LastRunTime)  (result $res)"
    if ($i.LastTaskResult -eq 0) { ok $lastLine } else { bad $lastLine }
  }
  Write-Host  "  next ping  : $($i.NextRunTime)  ($(HumanSpan $i.NextRunTime))"
  $last = LogLines $id | Select-Object -Last 1
  if ($last) { dim "  last log   : $last" }
}

function Cmd-Status($rest) {
  $id = $rest[0]
  if ($id) { ValidateProvider $id; Show-Detail $id; return }
  head "Claude Window Warmer - all providers"
  $rows = foreach ($pn in ProvIds) {
    $p = Prov $pn
    $t = TaskOf $pn
    $next = if ($t) { ($t | Get-ScheduledTaskInfo).NextRunTime } else { $null }
    [pscustomobject]@{
      id       = $pn
      provider = $p.label
      on       = if ($p.enabled) {'yes'} else {'-'}
      task     = if ($t) { $t.State } else { '-' }
      every    = "$($p.intervalHours)h$($p.intervalMinutes)m"
      next     = if ($next) { HumanSpan $next } else { '-' }
    }
  }
  ($rows | Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host
  dim "  detail: warmer status <id>    control: warmer enable|ping|install <id>    warmer list"
}

function Cmd-List {
  head "Known providers"
  $rows = foreach ($pn in ProvIds) {
    $p = Prov $pn
    [pscustomobject]@{
      id        = $pn
      provider  = $p.label
      installed = if (Detect $pn) {'yes'} else {'no'}
      enabled   = if ($p.enabled) {'yes'} else {'no'}
      every     = "$($p.intervalHours)h$($p.intervalMinutes)m"
      cmd       = $p.cmd
    }
  }
  ($rows | Format-Table -AutoSize | Out-String).TrimEnd() | Write-Host
  dim "  enable one:  warmer enable <id>     fix its command:  warmer set <id> cmd <path>"
}

function Cmd-Ping($rest) {
  $ids = ResolveIds $rest 'enabled'
  if ($ids.Count -eq 0) { warn "nothing enabled to ping - try: warmer ping <id>  or  warmer setup"; return }
  foreach ($id in $ids) {
    $t = TaskOf $id
    $before = (LogLines $id).Count
    if ($t) { Write-Host "pinging $id via scheduler..."; Start-ScheduledTask -TaskName $t.TaskName }
    else    { warn "[$id] task not installed - running worker directly"; & $Worker -Provider $id | Out-Null }
    WaitForPing $id $before 150
    $last = LogLines $id | Select-Object -Last 1
    if ($last -match 'exit=0') { ok "  $last" } else { bad "  $last" }
  }
}

function Cmd-Logs($rest) {
  if (-not (Test-Path $Log)) { warn "no log yet"; return }
  $n = 25; $id = $null
  foreach ($tok in $rest) {
    if ($tok -match '^\d+$') { $n = [int]$tok }
    elseif ($tok) { ValidateProvider $tok; $id = $tok }
  }
  if ($id) { LogLines $id | Select-Object -Last $n } else { Get-Content $Log -Tail $n }
}

function Cmd-Follow {
  if (-not (Test-Path $Log)) { warn "no log yet - waiting for first ping..."; New-Item -ItemType File $Log | Out-Null }
  Write-Host "tailing warm.log (ctrl-c to stop)..." -ForegroundColor DarkGray
  Get-Content $Log -Tail 10 -Wait
}

function Cmd-Stats($rest) {
  $id = $rest[0]; if ($id) { ValidateProvider $id }
  $lines = LogLines $id
  head ("Ping stats" + $(if ($id) { " - $id" } else { "" }))
  if ($lines.Count -eq 0) { warn "  no pings logged yet"; return }
  $okc  = (@($lines | Where-Object { $_ -match 'exit=0' })).Count
  $fail = $lines.Count - $okc
  $rate = [math]::Round(100 * $okc / $lines.Count, 1)
  Write-Host "  total : $($lines.Count)"
  ok        "  ok    : $okc  ($rate%)"
  if ($fail -gt 0) { bad "  fail  : $fail" } else { Write-Host "  fail  : 0" }
  if (-not $id) {
    dim "  by provider:"
    foreach ($pn in ProvIds) {
      $pl = LogLines $pn
      if ($pl.Count) {
        $po = (@($pl | Where-Object { $_ -match 'exit=0' })).Count
        Write-Host ("    {0,-12} {1}/{2} ok" -f $pn, $po, $pl.Count)
      }
    }
  }
  if ($fail -gt 0) {
    $lf = @($lines | Where-Object { $_ -notmatch 'exit=0' }) | Select-Object -Last 1
    bad "  last fail: $lf"
  }
}

function Cmd-Config { head "config.json"; Get-Content $CfgPath -Raw }

function Cmd-Interval($rest) {
  $id = $rest[0]
  if (-not $id) {
    head "intervals"
    foreach ($pn in ProvIds) { $p = Prov $pn; Write-Host ("  {0,-12} {1}h {2}m" -f $pn, $p.intervalHours, $p.intervalMinutes) }
    return
  }
  ValidateProvider $id
  $spec = @(); if ($rest.Count -gt 1) { $spec = $rest[1..($rest.Count-1)] }
  if ($spec.Count -eq 0) { $p = Prov $id; Write-Host "current $id interval: $($p.intervalHours)h $($p.intervalMinutes)m"; return }
  $iv = ParseInterval $spec
  if ($iv.H -eq 0 -and $iv.M -eq 0) { throw "interval can't be zero" }
  $c = Cfg; $c.providers.$id.intervalHours = $iv.H; $c.providers.$id.intervalMinutes = $iv.M; SaveCfg $c
  if (TaskOf $id) { RegisterTask $id; ok "$id interval set to $($iv.H)h $($iv.M)m and task re-registered" }
  else { ok "$id interval set to $($iv.H)h $($iv.M)m" }
}

function Cmd-Set($rest) {
  if ($rest.Count -lt 3) { throw "usage: warmer set <provider> <model|prompt|cmd|baseurl> <value...>" }
  $id = $rest[0]; ValidateProvider $id
  $key = ([string]$rest[1]).ToLower(); $val = ($rest[2..($rest.Count-1)] -join ' ')
  $c = Cfg; $p = $c.providers.$id
  switch ($key) {
    'model'   { $p.model = $val }
    'prompt'  { $p.prompt = $val }
    'cmd'     { $p.cmd = $val }
    'baseurl' {
      if (-not $p.env) { $p | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) -Force }
      if ($p.env.PSObject.Properties.Name -contains 'ANTHROPIC_BASE_URL') { $p.env.ANTHROPIC_BASE_URL = $val }
      else { $p.env | Add-Member -NotePropertyName ANTHROPIC_BASE_URL -NotePropertyValue $val }
    }
    default   { throw "unknown key '$key'. valid: model | prompt | cmd | baseurl" }
  }
  SaveCfg $c
  ok "set $id $key = $val"
  dim "(takes effect on the next ping - no reinstall needed)"
}

function Cmd-Install($rest) {
  $ids = ResolveIds $rest 'enabled'
  if ($ids.Count -eq 0) { warn "nothing enabled to install - name one (warmer install claude) or run warmer setup"; return }
  foreach ($id in $ids) {
    $c = Cfg; $c.providers.$id.enabled = $true; SaveCfg $c
    RegisterTask $id
    $i = TaskOf $id | Get-ScheduledTaskInfo
    ok "[$id] installed - next ping $($i.NextRunTime)"
  }
}

function Cmd-Uninstall($rest) {
  $ids = ResolveIds $rest 'all'
  $any = $false
  foreach ($id in $ids) {
    if (TaskOf $id) {
      Unregister-ScheduledTask -TaskName (TaskName $id) -Confirm:$false
      $c = Cfg; $c.providers.$id.enabled = $false; SaveCfg $c
      ok "[$id] task removed"; $any = $true
    }
  }
  Remove-LegacyTask
  if (-not $any) { warn "no warmer tasks were installed" }
}

function Cmd-Enable($rest) {
  $ids = ResolveIds $rest 'require'
  foreach ($id in $ids) {
    $c = Cfg; $c.providers.$id.enabled = $true; SaveCfg $c
    if (TaskOf $id) { Enable-ScheduledTask -TaskName (TaskName $id) | Out-Null } else { RegisterTask $id }
    ok "[$id] enabled"
  }
}

function Cmd-Disable($rest) {
  $ids = ResolveIds $rest 'require'
  foreach ($id in $ids) {
    if (TaskOf $id) { Disable-ScheduledTask -TaskName (TaskName $id) | Out-Null }
    $c = Cfg; $c.providers.$id.enabled = $false; SaveCfg $c
    warn "[$id] disabled (warmer enable $id to resume)"
  }
}

function Cmd-Restart($rest) {
  $ids = ResolveIds $rest 'enabled'
  foreach ($id in $ids) { RegisterTask $id; ok "[$id] re-registered" }
}

function Cmd-Doctor($rest) {
  head "Warmer doctor"
  $fail = 0
  # shared wiring
  $cred = Join-Path $HOME '.claude\.credentials.json'
  if (Test-Path $cred) {
    try { $j = Get-Content $cred -Raw | ConvertFrom-Json; if ($j.claudeAiOauth) { ok "  [ok]  subscription oauth present (claude/glm)" } else { warn "  [??]  credentials.json has no oauth block" } }
    catch { warn "  [??]  couldn't read credentials.json" }
  } else { warn "  [??]  no ~/.claude/.credentials.json (claude/glm need it - run 'claude' once to log in)" }
  $onPath = ([Environment]::GetEnvironmentVariable('Path','User')) -like "*$Root*"
  if ($onPath) { ok "  [ok]  folder on user PATH (warmer.cmd works in cmd)" } else { warn "  [??]  folder not on PATH - run warmer setup" }
  $prof = $PROFILE.CurrentUserAllHosts
  if ((Test-Path $prof) -and ((Get-Content $prof -Raw -ErrorAction SilentlyContinue) -match 'function warmer')) { ok "  [ok]  profile 'warmer' function installed" } else { warn "  [??]  profile function missing - run warmer setup" }
  if (Get-ScheduledTask -TaskName 'ClaudeWindowWarmer' -ErrorAction SilentlyContinue) { warn "  [??]  legacy ClaudeWindowWarmer task still present - run warmer setup" }

  $ids = ResolveIds $rest 'enabled'
  if ($ids.Count -eq 0) { warn "  nothing enabled - run warmer setup or warmer enable <id>"; return }
  foreach ($id in $ids) {
    $p = Prov $id
    head "  $($p.label) [$id]"
    if (Detect $id) { ok "    [ok]  cmd found ($($p.cmd))" } else { bad "    [!!]  cmd '$($p.cmd)' not found - warmer set $id cmd <path>"; $fail++ }
    $t = TaskOf $id
    if ($t) { $i = $t | Get-ScheduledTaskInfo; ok "    [ok]  task registered (state=$($t.State), next $($i.NextRunTime))" }
    else    { warn "    [??]  task not registered - warmer install $id" }
  }
  # live ping each
  Write-Host "  ...running live test ping(s)..." -ForegroundColor DarkGray
  foreach ($id in $ids) {
    $before = (LogLines $id).Count
    $t = TaskOf $id
    if ($t) { Start-ScheduledTask -TaskName $t.TaskName } else { & $Worker -Provider $id | Out-Null }
    WaitForPing $id $before 150
    $last = LogLines $id | Select-Object -Last 1
    if ($last -match 'exit=0') { ok "  [ok]  $id -> $last" } else { bad "  [!!]  $id -> $last"; $fail++ }
  }
  Write-Host ""
  if ($fail -eq 0) { ok "all good." } else { bad "$fail problem(s) found." }
}

function Cmd-Setup {
  head "Setting up the 'warmer' global command"
  # 1. profile function (powershell, all hosts)
  $prof = $PROFILE.CurrentUserAllHosts
  if (-not (Test-Path $prof)) { New-Item -ItemType File -Path $prof -Force | Out-Null }
  $cur = [string](Get-Content $prof -Raw -ErrorAction SilentlyContinue)
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
  # 3. migrate off the old single-provider task
  Remove-LegacyTask

  # 4. auto-detect which clis are installed; enable + register those (claude always on)
  head "Auto-detecting installed CLIs"
  $c = Cfg
  foreach ($id in $c.providers.PSObject.Properties.Name) {
    $found = Detect $id
    if ($found -or $id -eq 'claude') {
      $c.providers.$id.enabled = $true
      ok "  [found] $id  ($($c.providers.$id.label))"
    } else {
      dim "  [skip]  $id  (cmd '$($c.providers.$id.cmd)' not on PATH)"
    }
  }
  SaveCfg $c
  foreach ($id in (ProvIds)) { if ((Prov $id).enabled) { RegisterTask $id } }
  ok "  scheduled tasks registered for enabled providers"
  Write-Host ""
  warn "open a NEW terminal, then:  warmer status"
}

function Cmd-Open    { Invoke-Item $Root }
function Cmd-Version { Write-Host "warmer $Version" }

function Cmd-Help {
@"
warmer - keeps each AI-cli's rolling usage window freshly cycling

USAGE
  warmer [command] [provider] [args]

  most commands take an optional <provider> id (claude, codex, gemini, antigravity,
  kimi, qwen, glm, copilot, grok). omit it and info commands cover all providers,
  control commands act on all *enabled* ones. 'all' forces every provider.

INFO
  status [id]        per-provider table, or detail for one    (default)
  list               every provider: installed? enabled? interval, cmd
  stats [id]         success/fail counts from the log
  logs [N] [id]      last N log lines (optionally one provider)
  follow             live-tail the log
  config             print config.json
  doctor [id]        health check + live test ping(s)
  version

CONTROL
  ping [id|all]      fire a ping now
  install [id|all]   register scheduled task(s)
  uninstall [id|all] remove task(s)   (no arg = all)
  enable <id|all>    resume / register + mark enabled
  disable <id|all>   pause + mark disabled
  restart [id|all]   re-register (after a hand edit)
  setup              wire up the global command + auto-detect & install
  open               open the warmer folder

TUNING
  interval <id> <spec>   change cadence:  warmer interval claude 5h2m | 5:02 | 302
  set <id> model <m>     warmer set gemini model gemini-2.5-flash
  set <id> prompt <txt>  change the ping text
  set <id> cmd <path>    fix the cli command/path
  set <id> baseurl <url> override the api endpoint (env ANTHROPIC_BASE_URL)
"@ | Write-Host
}

# ---------- dispatch ----------
$cmd = if ($args.Count -ge 1) { ([string]$args[0]).ToLower() } else { 'status' }
$rest = @(); if ($args.Count -gt 1) { $rest = @($args[1..($args.Count-1)]) }

try {
  switch ($cmd) {
    'status'    { Cmd-Status $rest }
    'list'      { Cmd-List }
    'ls'        { Cmd-List }
    'stats'     { Cmd-Stats $rest }
    'history'   { Cmd-Stats $rest }
    'logs'      { Cmd-Logs $rest }
    'log'       { Cmd-Logs $rest }
    'follow'    { Cmd-Follow }
    'tail'      { Cmd-Follow }
    'config'    { Cmd-Config }
    'doctor'    { Cmd-Doctor $rest }
    'test'      { Cmd-Doctor $rest }
    'ping'      { Cmd-Ping $rest }
    'now'       { Cmd-Ping $rest }
    'install'   { Cmd-Install $rest }
    'uninstall' { Cmd-Uninstall $rest }
    'remove'    { Cmd-Uninstall $rest }
    'enable'    { Cmd-Enable $rest }
    'disable'   { Cmd-Disable $rest }
    'pause'     { Cmd-Disable $rest }
    'restart'   { Cmd-Restart $rest }
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
