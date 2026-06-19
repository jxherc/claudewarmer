# AI-CLI Window Warmer

Keeps your AI coding subscriptions' **rolling usage windows** always freshly cycling.
A Windows scheduled task fires one tiny headless ping per provider on an interval,
which starts a new rolling window on that subscription so the windows tile
back-to-back instead of leaving dead time.

Started life as a Claude-only warmer (Claude's **5-hour window**, pinged every
**5h 2m** so the previous window fully closes before the next opens). It now drives
**any** AI-CLI that has a warmable subscription window — one scheduled task per
provider, all from one `warmer` command.

The ping is a cheap call with no MCP servers / tools loaded, so the cost is negligible.

## Supported providers

Only CLIs with a **subscription rolling window** are worth warming. Pay-per-token /
bring-your-own-key tools (aider, goose, crush/opencode, cline, amp, droid, deepseek)
have no window to reset, so they're intentionally not included.

| id | provider | command | default interval |
|----|----------|---------|------------------|
| `claude`      | Claude Code (Anthropic)   | `claude.cmd`        | 5h 2m |
| `codex`       | Codex (OpenAI / ChatGPT)  | `codex exec`        | 5h 2m |
| `antigravity` | Google Antigravity        | `agy`               | 5h 2m |
| `kimi`        | Kimi (Moonshot)           | `kimi`              | 5h 2m |
| `qwen`        | Qwen Code (Alibaba)       | `qwen`              | 5h 2m |
| `glm`         | GLM (z.ai)                | `claude.cmd` → z.ai | 5h 2m |
| `copilot`     | GitHub Copilot CLI        | `copilot`           | 6 days |
| `grok`        | Grok (xAI)                | `grok`              | 24h |

> **Heads-up:** the non-Claude presets are *best-guess* invocations — the exact
> headless flag/model names vary by vendor and some change often. Nothing is
> hardcoded: every provider's command, model, prompt, interval and endpoint are
> editable from the CLI (`warmer set <id> ...`, `warmer interval <id> ...`) or by
> editing `config.json`. If a provider's ping fails, run `warmer logs <id>` and fix
> its command. `glm` drives the `claude` binary against z.ai's Anthropic-compatible
> endpoint, so it needs your z.ai token available in the environment.

## Install

### Windows (PowerShell + Task Scheduler)

```powershell
# from the folder, once:
& "$HOME\.claude-warmer\setup.ps1"
```

`setup` does four things:
1. adds a `warmer` function to your PowerShell profile (works in every PS session),
2. puts this folder on your user `PATH` (so `warmer` works in cmd.exe too, via `warmer.cmd`),
3. removes the old single-provider `ClaudeWindowWarmer` task if present,
4. **auto-detects** which provider CLIs are installed and registers a scheduled task
   for each (Claude is always on).

Then open a **new** terminal and run `warmer status`.

### Linux / macOS / WSL (bash + cron)

Same tool, ported to bash. Needs `jq` (`apt install jq` / `brew install jq`) and `crontab`.

```bash
# from the folder, once:
./setup.sh
source ~/.bashrc   # or open a new shell
warmer status
```

`setup.sh` adds a `warmer` shell function to your rc file, auto-detects installed
CLIs and registers a cron entry for each (Claude always on). Same `config.json`,
same subcommands as below — only the backend differs:

- **Scheduling is cron, not Task Scheduler.** cron can't express an arbitrary
  "every 5h2m" cadence, so each enabled provider gets one polling line
  (`*/5 * * * *`) and the worker (`warm-window.sh -p <id> --due`) self-gates: it
  only pings once the configured interval has elapsed since its last attempt
  (tracked in `warm.state`). Worst case a ping fires up to 5 min late, which only
  *widens* the gap between windows — it never fires early, so a window never
  overlaps the previous one.
- **The shared `config.json` ships Windows commands** (e.g. `%APPDATA%\npm\claude.cmd`).
  The bash side translates those automatically — a windows-style path/extension is
  reduced to the bare cli name (`claude.cmd` → `claude`) and resolved on `PATH`, so
  `claude`/`glm` work out of the box. Override any provider with `warmer set <id> cmd <path>`.
- **cron runs with a bare `PATH`**, so node/npm-installed clis would otherwise be
  invisible to it. `setup`/`install` bake your current `PATH` into each cron line,
  and the worker also widens `PATH` to the usual spots (homebrew, `~/.local/bin`,
  nvm's current node, bun, deno). If you switch node versions, run `warmer restart`.
- Files: `warmer.sh` (CLI), `warm-window.sh` (worker), `setup.sh` (bootstrap),
  `warm.state` (cron gate, gitignored).

## The `warmer` command

Most commands take an optional `<provider>` id. Omit it and **info** commands cover
all providers while **control** commands act on all *enabled* ones; pass `all` to
force every provider.

```
warmer [command] [provider] [args]

INFO
  status [id]        per-provider table, or detail for one      (default)
  list               every provider: installed? enabled? interval, cmd
  stats [id]         success/fail counts and rate from the log
  logs [N] [id]      last N log lines (optionally one provider)
  follow             live-tail the log
  config             print config.json
  doctor [id]        health check + a live test ping
  version

CONTROL
  ping [id|all]      fire a ping right now
  install [id|all]   register the scheduled task(s)
  uninstall [id|all] remove them   (no arg = all)
  enable <id|all>    resume / register + mark enabled
  disable <id|all>   pause + mark disabled
  restart [id|all]   re-register (after editing config by hand)
  setup              wire up the global command + auto-detect & install
  open               open the warmer folder

TUNING
  interval <id> <spec>   change cadence:  warmer interval claude 5h2m | 5:02 | 302
  set <id> model <m>     warmer set glm model glm-4.6
  set <id> prompt <txt>  change the ping text
  set <id> cmd <path>    fix the cli command / path
  set <id> baseurl <url> override the api endpoint (env ANTHROPIC_BASE_URL)
```

Examples:

```powershell
warmer                      # status table for every provider
warmer list                 # which CLIs are installed / enabled
warmer enable codex         # turn on a provider you have
warmer ping claude          # ping now, see the result
warmer ping                 # ping every enabled provider
warmer logs 50 codex        # last 50 codex pings
warmer interval grok 12h    # change one provider's cadence
warmer set kimi cmd kimi    # fix a provider's command
warmer doctor               # check everything + live ping the enabled ones
```

## Files

| File | What |
|------|------|
| `warmer.ps1`      | the CLI (all subcommands, provider registry) |
| `warm-window.ps1` | the worker each task runs: `warm-window.ps1 -Provider <id>` |
| `config.json`     | `taskPrefix` + a `providers` map (cmd, args, model, prompt, interval, env) |
| `setup.ps1`       | one-time bootstrap |
| `warmer.cmd`      | PATH shim for cmd / non-profile shells |
| `warm.log`        | ping history, provider-tagged (gitignored, local only) |

Each provider is one record in `config.json`. The worker builds the command by
substituting `{prompt}` / `{model}` into that provider's `args`; if `model` is blank
it drops the `{model}` token **and** the flag right before it (so `-m {model}`
disappears cleanly). `env` / `clearEnv` let a provider force the right endpoint and
ditch any inherited proxy keys. Task name per provider is `<taskPrefix>-<id>`
(e.g. `WindowWarmer-claude`).

## How it picks the right account (Claude / GLM)

This machine routes Claude through a third-party proxy by default (`cc-switch` →
`cn.meai.cloud`, set via the user `ANTHROPIC_*` env vars). That proxy has **no**
5-hour limit, and a scheduled task inherits that env — so the `claude` provider
forces `ANTHROPIC_BASE_URL=https://api.anthropic.com` (via its `env`) and clears any
inherited API key (via `clearEnv`), making every ping hit your real subscription via
its OAuth login (`~/.claude/.credentials.json`, auto-refreshed). The `glm` provider
uses the same trick pointed at z.ai instead.

## Caveats

- **You must stay signed in to Windows.** Tasks run in your logged-on session
  (locked or asleep is fine — `WakeToRun` wakes the machine). They will **not** run
  while you're fully signed out. To survive sign-out, change `-LogonType Interactive`
  to `-LogonType S4U` in the `RegisterTask` function of `warmer.ps1` and re-install.
- **Auth.** If a subscription login goes bad you'll see non-zero `exit=` lines in the
  log (e.g. a `401`) — run that provider's CLI once interactively to re-auth.
- **Best-guess presets.** See the providers note above — verify a provider's command
  with `warmer ping <id>` / `warmer logs <id>` and fix it with `warmer set` if needed.

## Uninstall

```powershell
warmer uninstall          # removes every warmer scheduled task
warmer uninstall codex    # or just one
```

(To also undo the global command, delete the `function warmer { ... }` line from your
PowerShell profile and remove the folder from your user `PATH`.)
