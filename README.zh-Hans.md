# warmer

[english](README.md)

让你的 claude 5 小时用量窗口一直轮转下去。它每隔 5 小时 1 分钟发一个很小的 `claude -p` ping，给你的订阅开一个新窗口。多出来的 1 分钟是为了确保旧窗口已经结束，这样窗口就能首尾相接。

这个 ping 是一次 haiku 调用，不带 mcp 服务器、不带 hook，也不保存会话，所以几乎没有开销。

只支持 claude。codex 和 agy 的支持已经去掉了。

## 安装

macos / linux（需要 `jq`，macos 15+ 自带）：

```bash
~/warmer/setup.sh
```

windows：

```powershell
& "$HOME\warmer\setup.ps1"
```

安装脚本会添加一个 `warmer` shell 函数（unix 上写进 `~/.zshrc` 或 `~/.bashrc`，windows 上写进你的 powershell profile），并装好定时任务：

- macos：`~/Library/LaunchAgents` 里的一个 launchd agent。不用 cron，因为 cron 任务读不到钥匙串里的 claude 登录信息。
- linux：一行 cron。
- windows：一个名为 `Warmer` 的计划任务。

在 macos 和 linux 上，调度器每 5 分钟唤醒一次 worker，worker 只有等间隔到了才会 ping。这样既能卡准 5 小时 1 分钟的节奏，机器从睡眠中醒来后也能在 5 分钟内补上。ping 失败会在 15 分钟后重试。

装完之后开一个新终端，然后运行 `warmer doctor`。

## 命令

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

## 文件

| 文件 | 作用 |
|------|------|
| `warmer.sh` / `warmer.ps1` | cli |
| `warm-window.sh` / `warm-window.ps1` | 定时任务运行的 worker |
| `config.json` | 模型、提示词、接口地址、间隔 |
| `setup.sh` / `setup.ps1` | 一次性安装 |
| `warmer.cmd` | windows 上给 cmd.exe 用的 shim |
| `warm.log` | ping 记录，保留最近 500 行 |
| `warm.state` | 上一次 ping 的时间和结果（仅 unix） |

## 注意事项

- 每次 ping 都会强制设置 `ANTHROPIC_BASE_URL=https://api.anthropic.com`，清空 `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`，并跳过你的用户设置（`--setting-sources project`）。所以就算你的 shell 或 `~/.claude/settings.json` 把 claude 指向了代理，它走的也还是你真正的订阅登录。
- 登录过期的话，日志里会出现非零的 `exit=` 行。运行一次 `claude`，重新登录就行。
- 机器得保持唤醒。windows 会设置 `WakeToRun`。macos 和 linux 只是在醒来后 5 分钟内 ping。
- macos：别把文件夹放在 `~/Desktop`、`~/Documents` 或 `~/Downloads` 里。没有完全磁盘访问权限的话，launchd 读不了这些目录。
- windows：你得一直保持登录。注销之后任务就不会运行。
- `warmer uninstall` 只会移除定时任务。如果连命令也不想要了，把 shell rc 或 powershell profile 里的 `warmer` 那行删掉。
