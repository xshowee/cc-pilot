# CC Pilot

[English](README.md) | 简体中文

在同一台 Mac 上，于自己的多个 Claude Code 和 ChatGPT 订阅账号之间切换，并在菜单栏查看每个账号的剩余额度。

> **声明**：cc-pilot 是独立的开源项目，与 Anthropic、OpenAI 没有任何关联，也未获得它们的认可或支持。
> 你用 cc-pilot 管理的每一个账号都应当属于你本人。cc-pilot 不能用来与他人共享账号，
> 也不能用来规避单个账号的用量限制。

## 它能做什么

在 Claude Code 里切换账号，原本只能先 `/logout` 再 `/login`：每次都要走浏览器授权，原来那个账号在这台机器上的登录也随之失效，不同终端也没法同时用不同账号。

cc-pilot 让每个账号各自独立：

- **账号之间登录互不影响**。每个账号有自己的登录状态，切来切去不需要重新登录。
- **切换只影响之后新启动的会话**。已经在运行的 Claude Code 一直使用它启动时的账号，所以不同终端可以同时使用不同账号。
- **单个终端临时用别的账号**：`CLAUDE_PROFILE=work claude`，不改变当前账号。
- **工作环境共用**。`CLAUDE.md`、技能、子代理、自定义命令、插件和项目会话历史由所有账号共用；设置（`settings.json`）和输入框的历史记录（按 ↑ 调出的那些）每个账号各有一份。
- **原来的环境就是默认账号**。你现在的 `~/.claude` 原样保留，名叫 `default`，不需要迁移。
- **从不自动切换**。切换永远由你手动触发。

### ChatGPT

通过 `codex` 命令行和 ChatGPT 桌面 App 使用的 ChatGPT 账号，cc-pilot 用同样的方式管理。Claude Code 和 ChatGPT 的账号互相独立：两边各有自己的当前账号，也可以有同名的账号。

- **每个 ChatGPT 账号是一个独立的 `CODEX_HOME` 目录**，有自己的登录状态。你现在的 `~/.codex` 就是名为 `default` 的 ChatGPT 账号，原样保留；其他账号在 `~/.codex-profiles/<名字>/`。
- **切换也作用于 App**。执行 `ccp chatgpt use work` 之后，新启动的 `codex` 会话使用 work，之后从 Dock、Spotlight 或 `open` 打开的 App（ChatGPT 桌面 App、Zed 等）也使用 work：cc-pilot 在 launchd 的环境里设置了 `CODEX_HOME`。ChatGPT 桌面 App 正在运行时，cc-pilot 先询问，再退出并重新打开它。已经在运行的会话继续使用原来的账号。
- **单个终端临时用别的账号**：`CODEX_PROFILE=work codex`，不改变 ChatGPT 的当前账号。
- **工作环境共用**。会话历史、`AGENTS.md`、技能、插件和规则由所有 ChatGPT 账号共用，在一个账号里开始的本地会话可以在另一个账号里继续；登录、设置（`config.toml`）、输入历史和桌面 App 自己的状态每个账号各有一份。

提供两个完全平等的入口：

- **命令行工具 `ccp`**：管理账号、切换当前账号（ChatGPT 用 `ccp chatgpt …`）。
- **菜单栏 App CC Pilot**：能做 `ccp` 做的事，还能在你点击刷新时显示每个账号的额度。

### 菜单栏 App

- 菜单栏显示两行：当前账号的订阅等级（如 Max 5x、Pro；不知道订阅等级时显示账号名称），以及这个账号的 5 小时窗口剩余额度（从未刷新过、也没有会话报告过实时额度时显示"—"）。也可以设置为只显示一个图标。
- 有了 ChatGPT（存在 `~/.codex` 目录）之后，菜单栏改为每个工具一行：工具图标，加上它当前账号的 5 小时窗口剩余额度。在齿轮菜单里，"菜单栏显示 Claude Code"和"菜单栏显示 ChatGPT"可以分别隐藏其中一个（只剩一个显示时不能再关掉）；只显示一个工具时，菜单栏回到上面的两行显示。ChatGPT 的订阅等级取最近一次刷新得到的套餐，没有时取登录信息里的套餐，再没有就显示账号名称。
- 面板上方列出 Claude Code 的账号，下方列出 ChatGPT 的账号，中间用两个工具的图标分隔；只有存在 `~/.codex` 时才显示 ChatGPT 这一段。每个账号以登录的邮箱为主要显示内容，账号名称作为副标题，另外显示组织和订阅等级（ChatGPT 显示套餐）。还没登录的显示"未登录"；两个账号登录的是同一个邮箱时，会标注"与某某是同一账号"，ChatGPT 按同一用户、同一工作区判断。用 API key 登录的 ChatGPT 账号会注明，不显示额度。
- 点一下即可切换当前账号，效果与 `ccp use` 或 `ccp chatgpt use` 完全相同。切换 ChatGPT 账号时如果 ChatGPT 桌面 App 正在运行，App 会询问是否立即重启 ChatGPT；选"以后再说"时账号照样切换，ChatGPT 下次打开时使用它。添加和删除账号时，App 打开"终端"执行 `ccp add` / `ccp rm`（ChatGPT 为 `ccp chatgpt add` / `ccp chatgpt rm`），流程与命令行完全一致。在 `ccp` 里做的修改会立刻反映到 App 上。
- 额度：点"刷新全部"（两个工具都刷新）或某个账号旁边的刷新按钮，获取 5 小时窗口和覆盖全部模型的周窗口的**剩余**百分比及重置时间；展开 Claude Code 账号可以看到按模型细分的周窗口和超额付费的使用情况。
  - 所有数字都是剩余百分比，不是 Claude Code `/usage` 里的已用百分比。
  - 颜色按剩余百分比：剩余 ≤20% 红色，≤50% 琥珀色，其余绿色。
  - 每个数字都标明获取时间，超过 30 分钟变灰；已经过了重置时间的窗口显示"已重置，待刷新"。
  - 有 `claude` 会话在运行时，这个账号的 5 小时窗口和覆盖全部模型的周窗口会随 Claude Code 自己收到的额度（经状态栏转交）实时更新，不额外发请求。同样，有 `codex` 会话或 ChatGPT 桌面 App 里的会话在运行时，这个账号的 5 小时窗口和周窗口随 codex 写进会话记录的额度实时更新。实时数据和刷新数据说的是同一个窗口时取已用较多的那份；重置时间更晚的窗口取代旧窗口。
  - 登录同一个邮箱的多个账号刷新时只请求一次。
  - 短期凭据过期的账号显示**待续期**：打开一次该账号的 `claude`（ChatGPT 是在该账号里打开一次 `codex` 或 ChatGPT）即可恢复。App 不发请求，也不替你续期。凭据已无法续期的 Claude Code 账号显示**需重新登录**。
- Token 用量：鼠标停在面板里的某个账号上，左侧弹出这台 Mac 在这个账号上用了多少 token（输入、输出、缓存写入、缓存读取，按模型细分）：当前 5 小时窗口、当前周窗口和从起算点到现在的累计，以及最近 24 小时和 30 天的历史。Claude Code 的数字来自它的本地会话记录；ChatGPT 的来自 codex 在 `~/.codex/sessions` 和 `~/.codex/archived_sessions` 里的会话记录，包括桌面 App 里的会话。清空累计就是把起算点移到现在，可以清空一个账号，也可以在设置菜单里清空全部账号（包括 ChatGPT 账号）；不碰 Claude Code 和 codex 的任何文件。Token 用量和额度是两回事，不能互相换算。
  - ChatGPT 的会话历史由所有账号共用，所以每次用量只算一次，会话被 resume 或 fork 也不会重复。会话算在正在写它的 codex 进程的 `CODEX_HOME` 所对应的账号上；找不到这样的进程时，算在输入历史（`history.jsonl`）里有这个会话的账号上。一小时内两者都找不到时，算在创建这个会话的那个账号上（会话记录里记着创建者的用户 ID），但只在这位用户在你的账号里恰好对应一个（同一用户、同一工作区算一个）时才这样算；对应不到或对应不止一个时不计入，宁可不算，也不算到错误的账号上。以前没有计入的会话也按这条重新计入。代价是：共享会话在登录了另一个用户的账号里续用、而当时 CC Pilot 没有运行时，续用部分会算到创建者名下。
- 界面根据系统语言显示中文或英文。只出现在菜单栏，没有 Dock 图标。"登录时启动"可选，默认关闭。

## 联网与隐私

CC Pilot 只访问下面三个地址：

| 地址 | 什么时候访问 |
| --- | --- |
| Claude Code 额度接口 `https://api.anthropic.com/api/oauth/usage` | **只在你点击**"刷新全部"或某个账号的刷新按钮时。启动 App、打开面板、切换账号都不会请求。请求头如实标明 `User-Agent: cc-pilot/<版本>`，不冒充官方客户端。 |
| ChatGPT 额度接口 `https://chatgpt.com/backend-api/wham/usage` | 与上一行相同：**只在你点击**"刷新全部"或某个 ChatGPT 账号的刷新按钮时。请求只带这个账号的 access token（`Authorization`）、工作区 ID（`ChatGPT-Account-Id`）和 `User-Agent: cc-pilot/<版本>`。 |
| 更新检查地址 `https://raw.githubusercontent.com/xshowee/cc-pilot/main/appcast.xml` | 由 [Sparkle](https://sparkle-project.org) 访问：开启"自动检查更新"（默认开启）时每天检查一次，距上次检查已满一天时会在 App 启动后不久检查；点"检查更新…"时立即检查。请求不附带系统信息。 |

确认安装更新后，Sparkle 从本仓库的 GitHub Releases 下载新版本的 DMG。不想自动检查，可以在面板右下角的齿轮菜单里关掉"自动检查更新"。

- **不收集任何使用数据**，不上报崩溃信息，没有任何统计或分析代码。
- **App 只读取凭据**。Claude Code 的凭据在钥匙串里，App 通过系统自带的 `/usr/bin/security` 读取；ChatGPT 的凭据在每个 ChatGPT 账号的 `auth.json` 里，App 从中读取邮箱、套餐、用户 ID 和工作区 ID，以及 access token 的过期时间。无论哪一边，token 都只在单次请求期间保存在内存里，从不写进日志、缓存文件或错误信息。
- **cc-pilot 从不写入、也从不续期凭据**。续期始终由 Claude Code 或 codex 自己完成。凭据只会在登出时由工具自己删除：Claude Code 由你执行 `/logout`（`ccp rm` 会为此打开 Claude Code）；`ccp chatgpt rm` 在你确认后，在该账号里执行 `codex logout`。凭据还在时，这两个命令都不会删除账号。
- `ccp` 不读取凭据，只检查它们是否存在：`ccp rm` 检查该账号的钥匙串项是否还在（不读取内容），`ccp chatgpt add` 和 `ccp chatgpt rm` 检查该账号的 `auth.json` 是否还在。
- 读取凭据不应该弹出钥匙串授权窗口。如果哪天出现了弹窗，请不要点"允许"：这说明 cc-pilot 与当前的 Claude Code 版本不兼容，App 也会这样提示你。
- **进程**。为了判断正在进行的会话属于哪个 ChatGPT 账号，App 会查看你自己的、名字以 `codex` 开头的进程：每个进程读一次环境变量、只保留 `CODEX_HOME`，并列出它们打开的文件。用的是 `lsof` 所用的同一套系统接口（libproc、sysctl），不为此启动任何程序。`ccp chatgpt rm` 为了确认账号是否仍在使用，执行一次 `ps -A -E`，只找 `CODEX_HOME` 是这个账号的 `codex` 进程和 ChatGPT 桌面 App。进程环境里的其他内容一概不保留。

## 它会碰哪些东西

| 位置 | cc-pilot 做什么 |
| --- | --- |
| `~/.zshrc` | 征得你的同意后，在末尾加**一行**（见下面"安装"）。执行多次也只有一行；卸载时只删除这一行。其余内容一个字节都不动。 |
| `~/.cc-pilot/` | `ccp` 命令和 `claude`、`codex` 包装函数的安装位置，由 App 安装和更新。 |
| `~/.claude-profiles/` | 除默认账号以外的账号，每个账号一个目录：`~/.claude-profiles/<名字>/`；以及记录当前账号的文件 `~/.claude-profiles/active`，和存放各账号最新实时额度的 `~/.claude-profiles/.live-quota/`。 |
| `~/.claude/`、`~/.claude.json`（默认账号） | **只读**。新建账号时，从 `~/.claude.json` 复制 MCP 服务器和项目信任设置、从 `~/.claude/settings.json` 复制设置；新账号里的共享资源是指向 `~/.claude/` 的软链接；App 从 `.claude.json` 读取账号资料（邮箱、组织、订阅等级）用于显示。 |
| 钥匙串 | **只读**，见上面"联网与隐私"。 |
| `~/.codex-profiles/` | 除默认账号以外的 ChatGPT 账号，每个账号一个目录：`~/.codex-profiles/<名字>/`（即它的 `CODEX_HOME`）；以及记录 ChatGPT 当前账号的文件 `~/.codex-profiles/active`。新账号一开始只有 `config.toml` 和指向 `~/.codex/` 的软链接，`auth.json` 由 `codex login` 写入。 |
| `~/.codex/`（ChatGPT 默认账号） | cc-pilot 不修改默认账号的登录、设置和其中的文件。`ccp chatgpt add` 在 `~/.codex/` 或其中的共享目录（`sessions`、`archived_sessions`、`thread-writer-locks`、`.tmp`、`skills`、`plugins`、`rules`）不存在时创建它们，并把其中的 `config.toml` 复制到新账号。之后，在其他账号里运行的 codex 也会写入这里：会话数据库经账号 `config.toml` 里的 `sqlite_home`，会话文件经软链接。App 读取 `sessions`、`archived_sessions` 里的会话记录，以及每个 ChatGPT 账号的 `auth.json` 和 `history.jsonl`。 |
| launchd 环境变量 `CODEX_HOME` | `ccp chatgpt use` 用 `launchctl setenv` 把它设为 ChatGPT 当前账号的目录，之后打开的 App 都使用这个账号；切回 `default` 时用 `launchctl unsetenv` 删除它。它在注销或重启前一直有效；App 每次启动时按 ChatGPT 当前账号重新设置一次（只在 `~/.codex-profiles/` 存在时）。不安装 LaunchAgent。 |
| ChatGPT 桌面 App | 它正在运行时切换 ChatGPT 账号，cc-pilot 先询问，你同意后才正常退出它并重新打开。第一次会由 macOS 询问是否允许控制 ChatGPT（"自动化"）；不允许时账号照样切换，并告诉你怎么自己重启 ChatGPT。 |
| ChatGPT 后台服务 | `ccp chatgpt rm` 在你确认后，用普通的终止信号停止桌面 App 为该账号运行的后台服务（桌面 App 装在账号目录 `packages/app-server-daemon/` 下的 `codex app-server`，App 退出后它仍在运行）。不会停止其他任何进程：其他 `app-server`（例如 IDE 的 Codex 扩展运行的）算作账号仍在使用。 |
| `~/Library/Application Support/cc-pilot/` | App 的 Token 用量账本（`token-usage.sqlite`）：按账号和模型的 token 数、每份会话记录读到了哪里、每个会话属于哪个账号。不含对话内容。 |
| "终端" | 在 App 里添加或删除账号时，App 打开一个新的终端窗口执行 `ccp add` / `ccp rm`（或 `ccp chatgpt add` / `ccp chatgpt rm`）。第一次会由 macOS 询问是否允许 CC Pilot 控制"终端"；不允许也没关系，App 会给出命令让你自己复制执行。 |

cc-pilot **不会**：

- 修改或替换 Claude Code 或 codex 的可执行文件。包装函数用 `command claude` / `command codex` 调用真正的程序，它们的自动更新照常进行。
- 修改默认账号的任何内容，或者迁移它（`ccp chatgpt add` 只在 `~/.codex` 里创建缺少的共享目录，见上表）。
- 写入、复制或续期 `auth.json`。
- 影响 `~/.zshrc` 里你已有的其他 Claude Code 包装函数或别名。
- 在只有默认账号、或者当前账号就是默认账号时改变 `claude` 的行为，只有实时额度例外：包装函数加一个 `--settings` 覆盖，把 Claude Code 的状态栏交给 `ccp statusline`，它把你自己的状态栏原样转出。不修改任何 `settings.json`；在 App 的设置里关掉后，`claude` 和接入之前完全一样。
- 在 ChatGPT 当前账号是默认账号、你也没有设置 `CODEX_HOME` 时改变 `codex` 的行为：包装函数直接执行 `command codex`。

注意，共享资源是软链接，所以在任何一个账号里安装技能或插件，改的都是 `~/.claude/`（ChatGPT 是 `~/.codex/`）里的那一份，这个工具的所有账号同时生效。设置不是共享资源：在某个账号里由 Claude Code 修改设置（比如执行 `/model`、`/advisor`），只影响这个账号；每个 ChatGPT 账号的 `config.toml` 也是如此。

## 系统要求

- macOS 13 或更高版本，同时支持 Apple Silicon 和 Intel。
- zsh（macOS 的默认 shell）。
- 已经安装 Claude Code，并且在 zsh 里能直接执行 `claude`。
- 使用 ChatGPT 账号时：已经安装 Codex CLI，并且在 zsh 里能直接执行 `codex`（`ccp chatgpt add`、`ccp chatgpt rm` 要执行 `codex login`、`codex logout`）。ChatGPT 桌面 App 可装可不装。

## 安装

1. 从 [GitHub Releases](https://github.com/xshowee/cc-pilot/releases/latest) 下载 `CCPilot-<版本>.dmg`。App 使用 Developer ID 签名，并已通过 Apple 公证。
2. 打开 DMG，把 CC Pilot 拖进"应用程序"文件夹，然后打开它。
3. 首次运行时，App 会说明并询问是否接入 zsh。选择"添加到 ~/.zshrc"后，App 把 `ccp` 和 `claude`、`codex` 包装函数安装到 `~/.cc-pilot/`，再在 `~/.zshrc` 末尾加上这一行：

   ```zsh
   source "$HOME/.cc-pilot/cc-pilot.zsh"  # cc-pilot
   ```

   选"暂不"则不修改任何文件，之后可以从面板右下角的齿轮菜单 › "接入 zsh…"重新开始。
4. 新开一个终端窗口（已打开的终端可以执行 `source ~/.zshrc`），`ccp` 就可以用了。

以后 App 每次更新，都会把 `~/.cc-pilot/` 更新到新版本，不再询问，也不再改 `~/.zshrc`。

**不装 App、只用命令行**：把本仓库的 `shell/` 目录复制为 `~/.cc-pilot/`，然后执行 `~/.cc-pilot/bin/ccp init`。它会先列出要加的那一行并询问，回答 `y` 才写入。

## 上手

```zsh
ccp add work        # 新建账号 work，并直接进入它的 Claude Code 完成首次引导和登录，完成后退出
ccp use work        # 切换：之后新启动的 claude 使用 work
claude              # 新开的终端里，这就是 work 账号
ccp use default     # 切回原来的环境

CLAUDE_PROFILE=work claude   # 只在这一次、这个终端里临时使用 work，不改变当前账号
```

新账号第一次启动时，会经历 Claude Code 自带的首次引导和登录流程，就像全新安装一样。新账号的登录与默认账号互不影响。

`claude` 决定使用哪个账号时，按以下优先级从高到低判断：

1. 环境里已经设置了 `CLAUDE_CONFIG_DIR`：cc-pilot 完全不干预，原样调用 Claude Code。
2. 设置了 `CLAUDE_PROFILE`：使用它指定的账号。
3. 否则使用当前账号。

当前账号指向一个已经不存在的账号时，`claude` 会报错并告诉你怎么修复，不会悄悄改用默认账号，以免在不知情时消耗错误账号的额度。

ChatGPT 的用法相同（`ccp codex …` 与 `ccp chatgpt …` 完全一样）：

```zsh
ccp chatgpt add work         # 新建 ChatGPT 账号 work，并在其中执行 codex login
ccp chatgpt use work         # 切换：之后新启动的 codex 和之后打开的 App 使用 work；重启 ChatGPT 前会先询问
CODEX_PROFILE=work codex     # 只在这一次、这个终端里临时使用 work，不改变 ChatGPT 当前账号
ccp chatgpt use default      # 切回 ~/.codex
```

`codex` 决定使用哪个 ChatGPT 账号时，按以下优先级从高到低判断：

1. 设置了 `CODEX_PROFILE`：使用它指定的账号。
2. 环境里的 `CODEX_HOME` 是你自己指定的目录（不是 `~/.codex`，也不在 `~/.codex-profiles/` 下）：cc-pilot 完全不干预，原样调用 codex。
3. 否则使用 ChatGPT 当前账号。指向 `~/.codex` 或 `~/.codex-profiles/` 下的 `CODEX_HOME` 视为 cc-pilot 留下的（从 Dock 打开的终端会从 launchd 继承它，可能是切换之前的值），按当前账号重设。

和 `claude` 一样，账号不存在时报错，不启动 codex，也不会改用默认账号。

## `ccp` 命令

| 命令 | 作用 |
| --- | --- |
| `ccp ls` | 列出所有账号，当前账号前面标 `*`。第一行总是 `default`。 |
| `ccp current` | 只输出当前账号的名字，方便在脚本或提示符里使用。只看当前账号，不看 `CLAUDE_PROFILE`。 |
| `ccp use <名字>` | 切换当前账号；`ccp use default` 切回默认账号。只影响之后新启动的会话。 |
| `ccp add <名字>` | 新建账号，并直接进入它的 Claude Code 完成首次引导和登录。不改变当前账号。Claude Code 在账号目录里的专用空目录 `.ccp-workdir` 中启动，而不是在你的当前目录；如果它询问是否信任这个目录，放心选 Yes，之后对这个账号执行 `ccp rm` 时不会再问。 |
| `ccp rm <名字>` | 删除账号：先请你确认，然后打开该账号的 Claude Code，请你在里面执行 `/logout` 并退出；确认已经登出后才删除。默认账号和当前账号不能删除。Claude Code 同样在账号的 `.ccp-workdir` 中启动，删除账号时一并删除。 |
| `ccp chatgpt ls` | 列出所有 ChatGPT 账号（`~/.codex` 是 `default`，其他在 `~/.codex-profiles/` 下），当前账号前面标 `*`。`ccp codex ls` 与之相同。 |
| `ccp chatgpt use <名字>` | 切换 ChatGPT 当前账号：之后新启动的 `codex` 和之后打开的 App（ChatGPT、Zed 等，经 `launchctl setenv CODEX_HOME`）都用它；ChatGPT 桌面 App 正在运行时询问是否重启它，`--restart` / `--no-restart` 不询问。只在一个终端里临时使用：`CODEX_PROFILE=<名字> codex`。 |
| `ccp chatgpt add <名字>` | 新建 ChatGPT 账号，并在其中运行 `codex login`。它的 `config.toml` 从 `~/.codex/config.toml` 复制一份（`sqlite_home` 指向 `~/.codex`），会话、`AGENTS.md`、技能、插件和规则是指向 `~/.codex` 的软链接，所有账号共享；登录和设置每个账号一份。登录没有完成时保留账号，并给出之后登录的命令。不改变当前 ChatGPT 账号。 |
| `ccp chatgpt rm <名字>` | 删除 ChatGPT 账号。默认账号、当前账号、`launchctl` 里仍指向的账号不能删除；仍在使用中的账号也不能删除：只要有 `codex` 进程、其他 `app-server` 进程（例如 IDE 的 Codex 扩展）或 ChatGPT 桌面 App 带着这个账号的 `CODEX_HOME` 在运行，就列出它们，不询问直接停下。否则先请你确认；桌面 App 为它运行的后台服务（账号目录 `packages/app-server-daemon/` 下的 `codex app-server`）在运行时先停止它，然后在其中执行 `codex logout`，确认 `auth.json` 已不在才删除。只删除账号自己的文件，`~/.codex` 里共享的会话、技能等保持不变。 |
| `ccp init [--yes]` | 接入 zsh：征得同意后在 `~/.zshrc` 末尾加上接入行；`--yes` 不询问。已经接入时什么都不改。 |
| `ccp uninstall` | 从 `~/.zshrc` 里删除 `ccp init` 加的那一行，其他内容不动。 |

两个工具的账号名称都只能由字母、数字、`.`、`_` 和 `-` 组成，并且以字母或数字开头；`default` 和 `active` 是保留名。

## 已知局限

- **哪些入口不会跟着切换**：切换靠的是 zsh 里的 `claude` 包装函数，所以不经过它启动的 Claude Code 不受切换影响，始终使用默认账号。包括：
  - IDE 插件（比如 VS Code、JetBrains 里的 Claude Code）；
  - Claude Desktop；
  - zsh 以外的 shell（bash、fish 等）。
- **ChatGPT 的 App 跟随 launchd，而 launchd 重启后就忘了**。重启 Mac 或重新登录后，在 CC Pilot 运行之前打开的 App 使用 ChatGPT 默认账号，直到 CC Pilot 启动（或者你执行 `ccp chatgpt use`）重新设置 `CODEX_HOME`；打开"登录时启动"可以缩短这段时间。切换时已经在运行的程序（编辑器、zsh 以外的 shell 等）继续使用它们启动时的 `CODEX_HOME`；只有 zsh 里的 `codex` 经过包装函数，总是使用当前账号。
- **ChatGPT 桌面 App 同一时间只能用一个账号**。切换 ChatGPT 账号会重启它，正在进行的任务会中断。
- **共享的 ChatGPT 会话有局限**。只有本地会话是共享的：ChatGPT 的普通聊天存在网上，跟着各自的账号走。桌面 App 侧边栏里的项目分组每个账号一份，所以在另一个账号里开始的会话出现在最近的会话里，而不在它的项目下。上游 Codex 将来可能让 `codex resume` 只列出当前账号的会话；cc-pilot 不会去绕过它。
- **MCP 服务器和项目信任设置只在创建时复制一次**。`ccp add` 从默认账号的 `~/.claude.json` 里只复制 `mcpServers`（用户级 MCP 服务器）和 `projects`（项目信任设置）两项，作为新账号的初始值。之后各账号各自独立变化，不会保持同步：在默认账号里新加的 MCP 服务器，不会出现在已经建好的账号里，反之亦然。claude.ai 账号里配置的连接器跟账号走，不在复制范围内。
- **设置只在创建时复制一次**。`ccp add` 把默认账号的 `~/.claude/settings.json` 复制为新账号的初始设置（`ccp chatgpt add` 对 `~/.codex/config.toml` 也是这样），之后各账号各自独立变化：在一个账号里改主题、状态栏、hooks 等，其他账号不会跟着变。这样不同订阅等级的账号可以用不同的模型和 advisor。插件是共享的，但"是否启用"记在各账号的设置里：在一个账号里装好并启用的插件，在其他账号里需要用 `/plugin` 再启用一次。
- **账号不能改名**。钥匙串里存凭据的那一项，名字是由账号目录的路径算出来的，改名就会丢失登录状态。想换名字，正确的做法是：用新名字 `ccp add` 新建一个账号并登录，再用 `ccp rm` 删除旧账号（删除时会引导你先登出）。
- **依赖 Claude Code 的内部实现**。钥匙串项的命名方式、`.claude.json` 里账号资料的结构、额度接口的地址和字段都没有官方文档，是按 Claude Code 2.1.309 的实际行为实现的。Claude Code 更新后如果不再兼容，App 会提示"与当前 Claude Code 版本不兼容"或"接口可能已变化，请更新 cc-pilot"，而不是显示猜出来的数字。
- **也依赖 Codex 的内部实现**。`auth.json` 的结构、ChatGPT 额度接口和会话记录的格式都没有官方文档，是按 ChatGPT 桌面 App 26.1027 和 Codex CLI 0.153.4 的实际行为实现的。更新后如果不再兼容，App 会提示"与当前 ChatGPT 版本不兼容"或额度接口可能已变化。
- ChatGPT 桌面 App 和 Zed（codex-acp）不写 `history.jsonl`。它们在 CC Pilot 没有运行时进行的会话，既没有写入进程、也没有 `history.jsonl` 记录，按创建会话的那个账号计；只有创建者在你的账号里对应不到、或对应不止一个时，它的 Token 用量才不计入。
- 使用 API key（Claude Code 或 ChatGPT）或 `setup-token` 生成的长期 token 登录时，不支持额度显示。

## 卸载

1. （可选）如果不再需要那些账号，先用 `ccp use default` 切回默认账号，再用 `ccp rm <名字>` 逐个删除（当前账号不能删除）。这样每个账号都会先登出，钥匙串里不会留下仍然有效的凭据。
2. 如果用过 ChatGPT 账号，执行 `ccp chatgpt use default`：它同时会从 launchd 的环境里删除 `CODEX_HOME`，之后打开的 App 重新使用 `~/.codex`。（可选）然后用 `ccp chatgpt rm <名字>` 删除其他 ChatGPT 账号，每个账号都会先用 `codex logout` 登出。
3. 执行 `ccp uninstall`（或者在面板右下角的齿轮菜单 › "移除 zsh 接入…"），删除 `~/.zshrc` 里的接入行。
4. 退出 CC Pilot，把它从"应用程序"文件夹删除。

默认账号（`~/.claude`、`~/.claude.json`、`~/.codex` 和它们的登录）始终不受影响。卸载之后，新开的终端里 `claude` 和 `codex` 的行为与安装 cc-pilot 之前完全一样。

如果想把痕迹清理干净，还可以手动删除：

- `~/.cc-pilot/`：`ccp` 和包装函数（`ccp uninstall` 保留它）；
- `~/.claude-profiles/`：其余账号和当前账号记录。没有先 `ccp rm` 就直接删除时，这些账号的凭据还留在钥匙串里（名为 `Claude Code-credentials-` 加 8 位十六进制的项），可以用"钥匙串访问"删除；
- `~/.codex-profiles/`：其余 ChatGPT 账号和 ChatGPT 当前账号记录。没有先 `ccp chatgpt rm` 就直接删除时，这些账号的 `auth.json` 会被删掉，但没有经 codex 登出。它们开始的会话留在共用的 `~/.codex` 里；
- `~/Library/Application Support/cc-pilot/`：Token 用量账本；
- App 的偏好设置：`defaults delete com.ccpilot.app`。

## 从源码构建

需要 Xcode 或 Command Line Tools（`swiftc`）。不需要 Xcode 工程：

```zsh
./scripts/check.sh        # 统一检查入口：zsh 语法检查、shell 黑盒测试、App 核心的检查程序、App 类型检查
./scripts/build-app.sh    # 本机架构、ad-hoc 签名的开发构建 → build/CC Pilot.app
open "build/CC Pilot.app"
```

第一次构建时会下载固定版本的 Sparkle 到 `build/deps/` 并校验 SHA-256，之后不再联网。目录结构：

```
shell/          zsh 包装函数和 ccp（原样安装为 ~/.cc-pilot/，见 shell/README.md）
Sources/Core/   App 核心（两个工具）：账号、切换、凭据读取、额度获取与解析、Token 用量（不含界面）
Sources/App/    SwiftUI 菜单栏界面
Resources/      Info.plist、本地化字符串、entitlements、工具图标
tests/          shell 黑盒测试、App 核心的检查程序、假的 claude / codex / security / launchctl / osascript / open / ps
docs/           设计决策（docs/adr/）与发布流程（docs/release.md）
```

术语见 [GLOSSARY.md](GLOSSARY.md)，设计决策见 [docs/adr/](docs/adr/)，签名、公证和发布流程见 [docs/release.md](docs/release.md)。

## 许可证

[MIT](LICENSE)
