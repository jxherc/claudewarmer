# warmer

[english](README.md)

让你的 claude 5 小时用量窗口一直轮转下去。它会读取当前 5 小时窗口的重置时间（和 `/usage` 里显示的一样），在重置后 1 分钟发一个很小的 `claude -p` ping，让下一个窗口马上开始。如果你自己用 claude 开了一个窗口，它会发现，然后把 ping 改到那个窗口重置之后。

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

在 macos 和 linux 上，调度器每分钟运行一次 worker。worker 用你的 claude 登录信息，从 claude 的用量接口读取重置时间。这个接口有频率限制，所以每个窗口大约只读一次；读不到的时候，每 5 分钟再试一次。一直读不到的话，就退回到每 5 小时 1 分钟 ping 一次（`warmer interval`）。ping 失败会在 15 分钟后重试。

windows 上还是按固定的 5 小时 1 分钟间隔 ping。

装完之后开一个新终端，然后运行 `warmer doctor`。

## 命令

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

## 文件

| 文件 | 作用 |
|------|------|
| `warmer.sh` / `warmer.ps1` | cli |
| `warm-window.sh` / `warm-window.ps1` | 定时任务运行的 worker |
| `config.json` | 模型、提示词、接口地址、备用间隔 |
| `setup.sh` / `setup.ps1` | 一次性安装 |
| `warmer.cmd` | windows 上给 cmd.exe 用的 shim |
| `warm.log` | ping 记录，保留最近 500 行 |
| `warm.state` | 上一次 ping、下一次检查、已知的 5 小时重置时间（仅 unix） |

## 注意事项

- 每次 ping 都会强制设置 `ANTHROPIC_BASE_URL=https://api.anthropic.com`，清空 `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`，并跳过你的用户设置（`--setting-sources project`）。所以就算你的 shell 或 `~/.claude/settings.json` 把 claude 指向了代理，它走的也还是你真正的订阅登录。
- 用量接口永远只请求 `api.anthropic.com`，不会走 `baseUrl`，所以你的登录信息不会发给代理。
- 登录过期的话，日志里会出现非零的 `exit=` 行。运行一次 `claude`，重新登录就行。
- 机器得保持唤醒。windows 会设置 `WakeToRun`。macos 和 linux 如果错过了重置，会在醒来后 1 分钟内 ping。
- macos：别把文件夹放在 `~/Desktop`、`~/Documents` 或 `~/Downloads` 里。没有完全磁盘访问权限的话，launchd 读不了这些目录。
- windows：你得一直保持登录。注销之后任务就不会运行。
- `warmer uninstall` 只会移除定时任务。如果连命令也不想要了，把 shell rc 或 powershell profile 里的 `warmer` 那行删掉。
