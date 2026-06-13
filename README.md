# Claude Window Warmer

Keeps your Claude **5-hour usage window** always freshly cycling. Every **5h 2m** a
Windows scheduled task fires one tiny `claude -p` ping, which starts a new rolling
window on your subscription (the same limit pool shared by Claude Code and Claude.ai).
The extra 2 minutes makes sure the previous window has fully closed before the next
one opens, so the windows tile back-to-back instead of leaving dead time.

The ping is a cheap Haiku call with no MCP servers loaded, so the cost is negligible.

It comes with a `warmer` command that works from anywhere — like `claude` itself.

## Install

```powershell
# from the folder, once:
& "$HOME\.claude-warmer\setup.ps1"
```

`setup` does three things:
1. adds a `warmer` function to your PowerShell profile (works in every PS session),
2. puts this folder on your user `PATH` (so `warmer` works in cmd.exe too, via `warmer.cmd`),
3. registers the scheduled task.

Then open a **new** terminal and run `warmer status`.

## The `warmer` command

```
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
  setup             wire up the global command + install task
  open              open the warmer folder

TUNING
  interval <spec>   change cadence:  warmer interval 5h2m | 5:02 | 302
  set model <m>     warmer set model sonnet
  set prompt <txt>  change the ping text
  set baseUrl <url> override the api endpoint
```

Examples:

```powershell
warmer                 # quick status
warmer ping            # ping now, see the result
warmer logs 50         # last 50 pings
warmer stats           # how reliable has it been
warmer interval 5h2m   # change cadence (re-registers automatically)
warmer doctor          # check everything + run a live ping
```

## Files

| File | What |
|------|------|
| `warmer.ps1`      | the CLI (all subcommands) |
| `warm-window.ps1` | the worker the task runs each cycle |
| `config.json`     | interval, model, prompt, endpoint |
| `setup.ps1`       | one-time bootstrap |
| `warmer.cmd`      | PATH shim for cmd / non-profile shells |
| `warm.log`        | ping history (gitignored, local only) |

## How it picks the right account

This machine routes Claude through a third-party proxy by default (`cc-switch` →
`cn.meai.cloud`, set via the user `ANTHROPIC_*` env vars). That proxy has **no**
Anthropic 5-hour limit, and a scheduled task inherits that env — so the worker
deliberately forces `ANTHROPIC_BASE_URL=https://api.anthropic.com` and clears any
inherited API key, making every ping hit your real subscription via its OAuth login
(`~/.claude/.credentials.json`, auto-refreshed). Override the endpoint with
`warmer set baseUrl <url>` if you ever want it pointed elsewhere.

## Caveats

- **You must stay signed in to Windows.** The task runs in your logged-on session
  (locked or asleep is fine — `WakeToRun` wakes the machine). It will **not** run
  while you're fully signed out. To survive sign-out, change `-LogonType Interactive`
  to `-LogonType S4U` in the `RegisterTask` function of `warmer.ps1` and re-run
  `warmer install`.
- **Auth.** If the subscription login goes bad you'll see non-zero `exit=` lines in
  the log (e.g. a `401`) — run `claude` once interactively to re-auth.

## Uninstall

```powershell
warmer uninstall
```

(That removes the scheduled task. To also undo the global command, delete the
`function warmer { ... }` line from your PowerShell profile and remove the folder
from your user `PATH`.)
