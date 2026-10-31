# Codex Desktop Notify

在 Windows 桌面上区分 Codex 的“本轮完成”和“等待回答”，点击提醒可请求返回发出通知的 VS Code 终端。

| 提醒 | 颜色 | 触发方式 |
| --- | --- | --- |
| 本轮完成 | 绿色 | Codex `Stop` hook，加上 TUI 完成通知提供终端地址 |
| 等待回答、计划选择、操作审批 | 橙色 | TUI 发出相应通知，由 VS Code 扩展转交 |

弹窗不会主动抢占输入焦点，显示简短预览，30 秒后自动关闭。它是本地脚本与扩展桥接工具，不是 Codex skill，也不是 OpenAI 官方产品。

## 支持范围

- Windows 10/11、Windows PowerShell 5.1、Python 3.11 或更新版本。
- Windows 本地 VS Code，或 Windows VS Code 配合 WSL 中运行的 Codex CLI。
- VS Code 扩展 **Terminal Notification**：`wenbopan.vscode-terminal-osc-notifier`，当前安装器仅支持 **0.1.4**。
- 已在 Codex CLI **0.166.0** 的通知配置下核对。其他版本需要自行确认事件名称、完成预览格式和 hook 支持。
- Node.js 20 或更新版本仅用于开发测试；终端通知桥接使用 VS Code 自带的运行时。

保留现有通知链路，不额外部署后台服务、不采集网络数据、不调用模型 API。VS Code 必须已启用终端 shell integration；Codex 需要在可被扩展监听的终端 shell execution 中启动。

## 安装

先安装上面的 Terminal Notification 扩展，克隆本仓库，然后在仓库目录运行：

```sh
python install.py
```

WSL 中若只有 `python3`，将示例命令中的 `python` 换成 `python3`。默认是只读预览，会检查扩展身份和版本，列出将使用的目录及 Codex 配置。确认预览后安装：

```sh
python install.py --apply
```

扩展安装在非默认位置时，增加 `--extension-dir`，指向包含 `package.json` 的扩展目录。参数使用运行安装器的当前系统所识别的路径。VS Code Insiders 的扩展需要显式指定目录。

安装器会：

1. 将原始文件快照保存在本机 `%LOCALAPPDATA%\CodexDesktopNotify\backups`。
2. 把通用弹窗脚本安装到 `%LOCALAPPDATA%\CodexDesktopNotify`。
3. 在扩展 `dist` 目录放置桥接模块，并对已核对的通知入口做小范围修改。
4. 输出使用者本机的 `Stop` hook 命令，并在上述运行目录生成 `hooks.example.json`。

**安装器不自动修改 Codex 配置，也不自动授予 hook 信任。** 将输出的 `Stop` 配置合并到当前 Codex 配置层旁边的 `hooks.json`，保留其他 hooks。若已有完成提醒 hook，应替换该条旧提醒，避免同一次完成触发两遍。请勿把整个现有配置覆盖成示例。

默认配置文件通常位于 Windows 的 `%USERPROFILE%\.codex\config.toml` 或 WSL 的 `~/.codex/config.toml`；设置了 `CODEX_HOME` 时使用相应目录。hook 配置放在该目录的 `hooks.json`。

将以下设置合并进 `config.toml` 已有的 `[tui]` 表；同一项只保留一份：

```toml
[tui]
notifications = ["approval-requested", "plan-mode-prompt", "async-question", "agent-turn-complete"]
notification_method = "osc9"
notification_condition = "always"
```

若设置 `notification_condition = "unfocused"`，焦点内可能没有 TUI 通知，完成弹窗也可能收不到点击返回地址。需要两类提醒均能返回终端时，使用上面的 `always`。

在 VS Code 扩展设置中保持 `terminalNotification.preferOsNotifications = true`。接着执行 **Developer: Reload Window**，重启 Codex，在 `/hooks` 中自行审阅并信任新 hook。更改 hook 命令后需要重新审阅。

## 隐私

仓库只包含源码、虚构测试、通用说明和许可文件。个人路径在安装时解析；安装器输出与运行目录中的示例会含有使用者本机路径，**不要把它们提交到仓库或贴入公开 issue**。

- 不读取对话数据库、历史对话或会话标题索引。弹窗只使用当前通知传入的文本、可选标题和终端名称。
- 调试日志默认关闭。Windows 父进程中设置 `CODEX_NOTIFY_DEBUG=1` 可启用本地事件日志；日志仅记录事件类型、时间和可选进程编号，不写入文本、会话标识或终端地址。
- 完成提醒为了匹配 TUI 预览，会在本机运行目录短暂保存当前回复文本及会话标识。这些记录会在弹窗关闭时删除；进程异常退出遗留的记录，在下一次启动提醒时清理超过 5 分钟的文件。5 分钟不是定时清理保证。
- 需要隐藏屏幕上的回复预览、标题和终端名称时，在启动 VS Code 和 Codex 的父进程环境中设置 `CODEX_NOTIFY_PREVIEW=0`，然后重启相关应用。此选项只隐藏显示内容，不取消完成路由所需的短暂本地记录。
- WSL 场景下，扩展和弹窗运行在 Windows 侧。请确保 Windows 父进程环境具有上述选项；仅在 WSL 中 `export` 不保证传入 Windows 进程。

工具没有遥测或上传逻辑。`.gitignore` 排除常见本地日志、凭据文件、运行目录和备份；发布前还应检查实际暂存内容，忽略规则不能代替人工复核。

## 点击返回的边界

提醒携带终端 ID，并通过 VS Code URI handler 请求显示对应终端。点击返回依赖 VS Code 的 URI 分发和原终端仍然存在；多个 VS Code 窗口时，操作系统可能把 URI 交给另一个窗口，不能保证跨窗口自动定位。终端已关闭、扩展已重载或 ID 已失效时，应手动返回会话。

如果多个会话在短时间内产生完全相同的完成预览，桥接模块会放弃猜测，完成弹窗可能仅能关闭。它不会冒险把回复关联到不确定的终端。

中途提问必须实际触发 TUI 的通知事件。普通回复中的问号或聊天文本不会被当作交互提醒。

扩展被更新或重新安装后，补丁可能被覆盖。先重新运行只读预览；安装器会拒绝未经核对的版本。不要为绕过检查而直接改版本号。

## 恢复

使用安装时打印的备份目录：

```sh
python install.py --restore "<backup-directory>"
```

恢复前会校验备份和当前文件；如果安装后文件又被修改，会停止，避免覆盖后续改动。恢复操作保留备份，随后需要重载 VS Code。安装器从未改动 Codex 配置，因此需要自行移除本工具的 hook，并按自己的偏好调整 TUI 设置。

## 开发与验证

没有 Python 或 Node.js 第三方包依赖：

```sh
python -m unittest discover -s tests -v
node --test tests/bridge.test.js
node --check bridge.js
python tests/check_privacy.py
```

Windows 上还可运行：

```powershell
powershell.exe -NoProfile -File tests\smoke.ps1
```

测试覆盖安装补丁、重复运行、原样恢复、后续用户改动保护、完成路由、提问触发、通知失败回退，以及日志和屏幕预览的隐私选项。PowerShell 检查仅执行辅助函数，不显示弹窗、不改变焦点、不修改用户配置。GitHub Actions 在 Linux 和 Windows 上运行相应检查；模拟检查不等于跨窗口点击或真实桌面视觉验证。

## 许可与来源

MIT License。与 Terminal Notification 的集成保留其上游许可，详见 [THIRD_PARTY.md](THIRD_PARTY.md)。

参考来源：

1. [OpenAI，Codex Hooks 官方说明](https://learn.chatgpt.com/docs/hooks)：配置发现与 hook 信任。
2. [OpenAI，Codex Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference)：TUI 通知设置。
3. [Pan Wenbo，Terminal Notification](https://github.com/wbopan/vscode-terminal-osc-notifier)：上游扩展与源码。
