# warmer

[简体中文](README.zh-Hans.md)

keeps your claude 5-hour usage window cycling. it reads when your current 5h window resets (the same time `/usage` shows) and sends one tiny `claude -p` ping 1 minute after, so the next window starts right away. if you start a window yourself by using claude, it sees that and moves its ping to that window's reset.

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

on macos and linux the scheduler runs the worker every minute. the worker reads the reset time from claude's usage api with your claude login. that api is rate limited, so it's read about once per window, and while it can't be read the worker checks again every 5 min. if it stays unreadable, pings fall back to every 5h 1m (`warmer interval`). a failed ping retries after 15 min.

windows still pings on the fixed 5h 1m interval.

open a new terminal after setup, then run `warmer doctor`.

## commands

```
warmer                 # status
warmer ping            # ping now
warmer logs 50         # last 50 pings
warmer stats
warmer follow          # live-tail the log
warmer interval 5h1m   # fallback when the reset can't be read
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
| `config.json` | model, prompt, endpoint, fallback interval |
| `setup.sh` / `setup.ps1` | one-time setup |
| `warmer.cmd` | cmd.exe shim for windows |
| `warm.log` | ping history, last 500 lines |
| `warm.state` | last ping, next check, known 5h reset (unix only) |

## notes

- every ping forces `ANTHROPIC_BASE_URL=https://api.anthropic.com`, clears `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`, and skips your user settings (`--setting-sources project`). so it hits your real subscription login even if your shell or `~/.claude/settings.json` points claude at a proxy.
- the usage api is always called on `api.anthropic.com`, never on `baseUrl`, so your login never goes to a proxy.
- if the login expires you'll see non-zero `exit=` lines in the log. run `claude` once and sign in again.
- the machine has to be awake. windows sets `WakeToRun`. macos and linux ping within a minute of waking if a reset was missed.
- macos: don't keep the folder in `~/Desktop`, `~/Documents` or `~/Downloads`. launchd can't read those without full disk access.
- windows: you have to stay signed in. the task won't run while you're signed out.
- `warmer uninstall` removes the schedule only. delete the `warmer` line from your shell rc or powershell profile if you want the command gone too.
