# warmer

keeps your claude 5-hour usage window cycling. every 5h 1m it sends one tiny `claude -p` ping, which starts a fresh window on your subscription. the extra minute makes sure the old window has closed first, so the windows line up back to back.

the ping is a haiku call with no mcp servers, no hooks and no saved session, so it costs almost nothing.

claude only. codex and agy support was dropped.

## install

macos / linux (needs `jq`, macos 15+ ships it):

```bash
~/warmer/setup.sh
```

windows:

```powershell
& "$HOME\warmer\setup.ps1"
```

setup adds a `warmer` shell function (`~/.zshrc` or `~/.bashrc` on unix, your powershell profile on windows) and installs the schedule:

- macos: a launchd agent in `~/Library/LaunchAgents`. not cron, because cron jobs can't read the claude login from the keychain.
- linux: one cron line.
- windows: a scheduled task named `Warmer`.

on macos and linux the scheduler wakes the worker every 5 min and the worker only pings once the interval is up. that's how it gets an exact 5h 1m cadence and still catches up within 5 min after the machine wakes from sleep. a failed ping retries after 15 min.

open a new terminal after setup, then run `warmer doctor`.

## commands

```
warmer                 # status
warmer ping            # ping now
warmer logs 50         # last 50 pings
warmer stats
warmer follow          # live-tail the log
warmer interval 5h1m   # also 5:01 or 301
warmer set model haiku
warmer set prompt <txt>
warmer set baseUrl <url>
warmer disable         # pause, warmer enable to resume
warmer doctor          # checks install + runs one live ping
warmer uninstall
```

## files

| file | what |
|------|------|
| `warmer.sh` / `warmer.ps1` | cli |
| `warm-window.sh` / `warm-window.ps1` | worker the schedule runs |
| `config.json` | model, prompt, endpoint, interval |
| `setup.sh` / `setup.ps1` | one-time setup |
| `warmer.cmd` | cmd.exe shim for windows |
| `warm.log` | ping history, last 500 lines |
| `warm.state` | time and result of the last ping (unix only) |

## notes

- every ping forces `ANTHROPIC_BASE_URL=https://api.anthropic.com`, clears `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`, and skips your user settings (`--setting-sources project`). so it hits your real subscription login even if your shell or `~/.claude/settings.json` points claude at a proxy.
- if the login expires you'll see non-zero `exit=` lines in the log. run `claude` once and sign in again.
- the machine has to be awake. windows sets `WakeToRun`. macos and linux just ping within 5 min of waking.
- macos: don't keep the folder in `~/Desktop`, `~/Documents` or `~/Downloads`. launchd can't read those without full disk access.
- windows: you have to stay signed in. the task won't run while you're signed out.
- `warmer uninstall` removes the schedule only. delete the `warmer` line from your shell rc or powershell profile if you want the command gone too.
