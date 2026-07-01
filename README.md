# warmer

warmer runs a tiny scheduled ping for the cli you pick: `claude`, `codex`, or `agy`.

The global command is `warmer`. The project folder is `~/warmer`.

## install

```powershell
& "$HOME\warmer\setup.ps1"
```

`setup` does three things:

1. adds/updates the `warmer` function in your PowerShell profile
2. puts `~/warmer` on your user `PATH`
3. registers the Windows scheduled task named `Warmer`

Open a new terminal after setup.

## commands

```powershell
warmer                 # status
warmer tools           # check claude/codex/agy
warmer use codex       # switch tool
warmer use claude
warmer use agy
warmer ping            # ping now
warmer logs 50         # last 50 pings
warmer stats
warmer interval 5h2m
warmer set model <m>   # model for the selected tool
warmer set prompt <txt>
warmer doctor          # checks install + runs one live ping
```

Only these tools are supported on purpose: `claude`, `codex`, and `agy`.

## files

| file | what |
|------|------|
| `warmer.ps1` | cli and subcommands |
| `warm-window.ps1` | worker the scheduled task runs |
| `config.json` | selected tool, interval, prompt, models |
| `setup.ps1` | one-time setup |
| `warmer.cmd` | cmd.exe/path shim |
| `warm.log` | ping history |

## notes

- `claude` uses `claude -p` and keeps using the official Anthropic endpoint from `baseUrl`.
- `codex` uses `codex exec --ephemeral --sandbox read-only`.
- `agy` uses `agy --print`.
- `warmer set model <m>` only changes the model for the currently selected tool.
- `warmer uninstall` removes the scheduled task. remove the profile function and PATH entry manually if you want the command gone too.
