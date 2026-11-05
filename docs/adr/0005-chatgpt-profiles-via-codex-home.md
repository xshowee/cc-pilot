# ChatGPT 档案按 CODEX_HOME 隔离，GUI 入口经 launchctl 跟随当前档案

ChatGPT 这个工具（ChatGPT 桌面 App 与 `codex` 命令行）的每个档案是一个独立的 `CODEX_HOME` 目录（默认档案即 `~/.codex`，其他档案在 `~/.codex-profiles/<name>/`），沿用 ADR 0001 的思路：切换只改写当前档案记录，cc-pilot 不覆盖 `auth.json`，也不续期凭据。与 Claude Code 不同的是，ChatGPT 的 GUI 入口也跟随当前档案：切换时用 `launchctl setenv CODEX_HOME` 指向当前档案目录（切回默认档案时 `unsetenv`），之后由 LaunchServices 启动的 App（Dock、Spotlight、`open`、Zed 等）都使用它。cc-pilot 只做切换，不退出、不重新打开 ChatGPT 桌面 App：它正在运行时只提示用户，由用户自己决定什么时候退出并重新打开。

实测（2026-11-04，ChatGPT.app 26.1027 内嵌 codex 0.166.0-alpha，codex CLI 0.153.4）：用 `open --env CODEX_HOME=…` 启动桌面 App 后，Codex 和普通聊天都使用该目录里登录的账号，`.codex-global-state.json`、sqlite、`sessions/` 全部落在该目录，`~/.codex` 未被改动；`launchctl setenv` 设置的变量会出现在之后经 LaunchServices 启动的 App 的环境里。

## Considered Options

- **覆盖 `auth.json`**（codex-pilot 的做法：退出桌面 App，把账号快照替换进 `~/.codex/auth.json`，再重新打开）。没有采用：cc-pilot 要写入凭据；正在运行的 `codex` 会话仍持有旧 token，续期时可能把旧账号写回；不同终端无法同时使用不同账号。
- **只隔离命令行，桌面 App 永远用默认档案**（与 Claude Code 的现状一致）。没有采用：ChatGPT 用户主要通过桌面 App 使用，不能切换桌面 App 就失去了这个功能的意义。
- **切换时经用户确认后替用户退出并重新打开桌面 App**（最初的做法）。没有采用：要 macOS"自动化"授权去控制 ChatGPT，退出可能卡在 App 自己的确认上、要等待和超时处理，还会中断正在进行的任务；用户更愿意切换只是切换，什么时候重启由自己决定。
- **装一个 LaunchAgent，登录时恢复 `launchctl` 环境变量**。没有采用：多占一个系统位置；接受下面"重启后"的限制。

## Consequences

- `launchctl setenv` 在重启或注销后失效。cc-pilot App 启动时重新设置；在它运行之前，GUI 入口使用默认档案。
- 从 Dock 打开的终端会继承 launchd 里的 `CODEX_HOME`，可能是旧值。因此 `codex` 包装函数把指向 `~/.codex-profiles/` 下或等于 `~/.codex` 的 `CODEX_HOME` 视为 cc-pilot 设置的、改用当前档案；只有指向其他路径才算用户直接指定（终端覆盖）。
- 切换时正在运行的桌面 App 继续使用旧档案，直到用户自己退出并重新打开它；切换本身不会中断它正在进行的任务。
- Codex 不会自动创建 `CODEX_HOME` 目录，新建档案时由 cc-pilot 创建。
- 删除档案时，cc-pilot 经用户确认后运行 `CODEX_HOME=<目录> codex logout`，由工具自己登出，确认 `auth.json` 已不存在后才删除目录。这比 Claude Code 那边"用户自己执行 /logout"多走了一步，README 的隐私说明要相应改写。
- Claude Code 这一侧不变：它的 IDE 插件和 Claude Desktop 仍按 ADR 0001 始终使用默认档案。
- 依赖 ChatGPT 桌面 App 遵守 `CODEX_HOME`；App 更新后需要复验。
