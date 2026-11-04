# cc-pilot 的 shell 部分

## 安装布局

本目录与安装后的 `~/.cc-pilot/` 一一对应，**安装就是把本目录原样复制过去**（`ccp`、App 安装器都按这个布局）：

```
~/.cc-pilot/
├── cc-pilot.zsh        入口：被 ~/.zshrc source；定义 claude、codex 包装函数，把 bin/ 加到 PATH 最前面
├── bin/ccp             命令行工具（可执行，#!/bin/zsh -f）
└── lib/
    ├── profiles.zsh    共享库：档案目录、当前档案记录、档案名规则、档案解析
    ├── keychain.zsh    共享库：钥匙串 service 名计算 _ccp_service_name
    ├── zshrc.zsh       共享库（只给 ccp 用）：~/.zshrc 的接入行与读写辅助
    ├── launch.zsh      共享库（只给 ccp 用）：以某个档案启动 Claude Code（ccp add / rm）
    ├── chatgpt-profiles.zsh  共享库：ChatGPT 档案目录、当前档案记录、档案解析（ADR 0005）
    ├── cmd-<命令>.zsh  ccp 每个子命令一个文件，定义 _ccp_cmd_<命令>（cmd-statusline.zsh 是状态栏转发，见下文）
    ├── cmd-chatgpt.zsh ccp chatgpt / ccp codex 的第二级分派与用法说明
    └── cmd-chatgpt-<子命令>.zsh  ccp chatgpt 每个子命令一个文件，定义 _ccp_cmd_chatgpt_<子命令>
```

- 安装根目录固定为 `~/.cc-pilot/`，不能放在 `~/.claude-profiles/` 下（那里的每个目录都会被当成档案）。
- 接入 zsh 就是在 `~/.zshrc` 里加一行 source（由 `ccp init` 写入，见下面"接入 zsh"）。
- App（`Sources/Core/ShellIntegration.swift`）内置本目录（`Contents/Resources/shell/`）：用户在首次运行引导里同意后，把它整体复制为 `~/.cc-pilot/` 再执行 `ccp init --yes`；之后每次启动，只要已安装过（或 `~/.zshrc` 里有接入行），内容与内置版本不同就整体替换，不再询问，也不改 `~/.zshrc`。`~/.cc-pilot` 是软链接时 App 不动它（便于开发时指向仓库）。设置里的"移除 zsh 接入"执行 `ccp uninstall`，保留 `~/.cc-pilot/`。
- `cc-pilot.zsh` 和 `bin/ccp` 都按自身所在位置找 `lib/`，所以直接 source 仓库里的 `shell/cc-pilot.zsh` 也能用；测试就是把本目录复制到临时 HOME 的 `.cc-pilot/` 再运行。

## 代码约定

- `cc-pilot.zsh` 只 source `lib/profiles.zsh` 和 `lib/chatgpt-profiles.zsh`（包装函数要用的辅助函数必须放在这两个文件里）；`bin/ccp` source `lib/` 下所有不以 `cmd-` 开头的 `.zsh` 文件，再只 source 被调用的那个 `cmd-<命令>.zsh`。新增共享库直接放进 `lib/` 即可。
- `lib/` 里的代码会进入用户的交互 shell：只定义 `_ccp_` 开头的函数，不定义全局变量；函数开头写 `emulate -L zsh`；出错只 `return`，不 `exit`。
- 输出位置：询问（如 `[y/N]`）、进度和结果写 stdout；错误（以 `ccp <命令>:` 开头）、用法说明和警告写 stderr。
- 系统工具用绝对路径（`/usr/bin/osascript`、`/usr/bin/shasum`）；`claude`、`codex`、`security` 按 PATH 查找，测试会在 PATH 最前面放假程序。例外：`ccp chatgpt` 用来改 launchd 环境、控制 ChatGPT 桌面 App 的 `launchctl`、`osascript`、`open`，以及 `ccp chatgpt rm` 查找守护进程用的 `ps` 也按 PATH 查找（spec 要求可被测试替换，`tests/fakes/` 里有同名假程序）；做 JSON 和 NFC 的 `/usr/bin/osascript` 仍用绝对路径。

## 接入 zsh（`ccp init` / `ccp uninstall`）

接入行（逐字节如下，`$HOME` 原样写入、不展开，两个空格后跟标记注释）：

```
source "$HOME/.cc-pilot/cc-pilot.zsh"  # cc-pilot
```

- `ccp init`：在 `~/.zshrc` **末尾**追加这一行（放在末尾，用户自己的 `claude` alias 或函数不会盖掉包装函数）。
  - 先列出这一行并询问，答案从标准输入读：`y`/`yes`（不分大小写）才继续；其他回答或标准输入为空都算拒绝，不改任何文件，退出码 1。
  - `--yes`（或 `-y`）跳过询问。App 安装器应当执行 `~/.cc-pilot/bin/ccp init --yes`，不要自己改 `~/.zshrc`，这样两者结果必然一致。
  - 已有与接入行**完全相同**的整行时什么都不改、也不询问，退出码 0；所以重复执行（包括 App 每次更新后重跑）只会有一行。注释掉的、前后多了空白的、改过的行都不算。
  - `~/.zshrc` 不存在时新建；不以换行结尾时先补一个换行；是软链接时写入它指向的文件，软链接不变。
  - `~/.cc-pilot/cc-pilot.zsh` 不存在时拒绝接入（退出码 1），所以必须先安装再 init。
  - 固定改 `$HOME/.zshrc`，不考虑 `ZDOTDIR`。
- `ccp uninstall`：删除所有与接入行完全相同的整行（连同结尾的换行），其余字节原样保留；不询问，`--yes` 可写可不写。
  - 没有 `~/.zshrc` 或没有接入行时不重写文件，退出码 0。删空后保留空文件。
  - 软链接保持不变，改写它指向的文件并保留权限；经同目录临时文件 rename 原子写入。
  - 已知差异：接入前最后一行没有换行时，init 补上的那个换行在卸载后保留（无法区分它是不是用户的）。
- 退出码：0 成功（含"已接入"/"无需卸载"），1 拒绝或失败，2 参数错误。

## 当前档案记录的写入格式（`ccp use`）

`~/.claude-profiles/active` 的内容是档案名加一个换行，例如 `work\n`；切回默认档案时写 `default\n`（不删除文件）。写入时在同一目录下用 `mktemp` 建临时文件 `.active.XXXXXX`，写完后 rename 到 `active`。App 的"切换"按同样的格式写。

档案名必须符合 `^[A-Za-z0-9][A-Za-z0-9._-]*$`，`default` 和 `active` 是保留名（`active` 与当前档案记录同路径）。共享库里对应 `_ccp_valid_name`（只检查字符规则）、`_ccp_reserved_name`（保留名）和 `_ccp_invalid_name_reason`（错误信息里的原因）；可用作档案目录的名字要两者同时满足。

档案名区分大小写：`ccp use`、`ccp rm`、包装函数（以及 App 的切换）都要求名字与 `~/.claude-profiles/` 下的目录名逐字节相同（`_ccp_profile_exists`）。macOS 的文件系统默认不分大小写，只用 `[[ -d ]]` 判断时 `Work` 也能找到 `work` 目录，但 `CLAUDE_CONFIG_DIR` 会变成 `.../Work`，钥匙串 service 名随之不同，表现为未登录。`ccp rm` 判断"是不是当前档案"时比较的是目录本身（`-ef`），所以记录里写的是 `Work` 时也删不掉 `work`。

`ccp ls` 第一行总是 `default`，之后按字节序列出 `~/.claude-profiles/` 下名字合规的目录（含指向目录的软链接）；当前档案前面是 `* `，其他是两个空格。`ccp current` 只看当前档案记录，不看 `CLAUDE_PROFILE`。

## ChatGPT 档案（`ccp chatgpt`）

`ccp chatgpt <子命令>` 与 `ccp codex <子命令>` 完全相同。ChatGPT 档案与 Claude 档案互相独立（各有当前档案，可以同名）：默认档案是 `~/.codex`（不设置 `CODEX_HOME`），其他档案是 `~/.codex-profiles/<名字>/`（即它的 `CODEX_HOME`），当前档案记录是 `~/.codex-profiles/active`，格式和档案名规则都与 Claude 一侧相同。共享库函数在 `lib/chatgpt-profiles.zsh`，都以 `_ccp_chatgpt_` 开头。

`ccp chatgpt ls` 的输出格式与 `ccp ls` 相同：第一行总是 `default`（不论 `~/.codex` 是否存在），之后按字节序列出 `~/.codex-profiles/` 下名字合规的目录；只显示名字，不读 `auth.json`。

### ccp chatgpt add 建立的档案（ADR 0006）

`ccp chatgpt add <名字>` 先做与 `ccp add` 相同的检查（名字规则、保留名、任何类型的同名项都算已存在），任何一项不通过都不改磁盘。然后在 `~/.codex-profiles/<名字>/` 里只放两类东西：

- 共享资源的软链接，各自指向 `~/.codex/` 中的同名项（绝对路径）。目录：`sessions`、`archived_sessions`、`thread-writer-locks`、`.tmp`、`skills`、`plugins`、`rules`，`~/.codex` 里还没有时先创建（`~/.codex` 本身不存在也一并创建）；文件：`AGENTS.md`，`~/.codex` 里没有时不建链接。清单和建立方式集中在 `chatgpt-profiles.zsh` 的 `_ccp_chatgpt_shared_dirs` / `_ccp_chatgpt_shared_files` / `_ccp_chatgpt_share_resources`（`ccp chatgpt rm` 删除时只删这些链接本身，不跟随它们）。
- `config.toml`：第一行是 `sqlite_home = "<~/.codex 的绝对路径>"`（TOML 基本字符串，转义 `\` 和 `"`；必须是顶层键，所以放第一行），之后是默认档案 `~/.codex/config.toml` 的原样内容（是软链接时取它指向的内容），只去掉其中顶层（第一个 `[表]` 之前）已有的 `sqlite_home`。默认档案没有时只有这一行；读不出时也只有这一行并给出提示。会话数据库靠 `sqlite_home` 落在 `~/.codex`。

不创建、不复制：`auth.json`、`installation_id`、`.codex-global-state.json`、`history.jsonl`、`sqlite/`（桌面 App 自己的库，issue 01 实测每个档案一份即可）。建链接或写 `config.toml` 失败时删除整个新档案目录（只删链接本身）。

然后以 `CODEX_HOME=<档案目录> command codex login` 登录（不经过包装函数，也不看 `CODEX_PROFILE`），不改变当前档案。`codex` 退出码非零或退出后档案里没有 `auth.json` 时保留档案，在 stderr 最后一行给出之后登录用的命令 `CODEX_HOME=<档案目录> command codex login`（`command` 绕过包装函数，否则包装函数会把 `~/.codex-profiles/` 下的 `CODEX_HOME` 换成当前档案），退出码非零。

### `ccp chatgpt use <名字> [--restart|--no-restart]`（ADR 0005）

切换逻辑只在这里实现一份，App 点击 ChatGPT 档案时在后台执行它（总是带 `--restart` 或 `--no-restart`），App 启动时执行 `ccp chatgpt use <当前档案> --no-restart` 恢复重启后丢失的 launchd 环境变量。

1. 名字检查与 `ccp use` 相同；不通过时什么都不改，退出码 1（参数错误 2）。
2. 写 `~/.codex-profiles/active`（格式、原子写入与 `ccp use` 相同）。
3. `launchctl setenv CODEX_HOME <档案目录>`；`default` 时 `launchctl unsetenv CODEX_HOME`。之后经 LaunchServices 打开的 App（Dock、Spotlight、`open`、Zed 等）使用新档案。失败时退出码 1。
4. ChatGPT 桌面 App（`com.openai.codex`）正在运行时询问"重启 ChatGPT？[y/N]"（只认 `y`/`yes`，读不到算否；`--restart`/`--no-restart` 不询问）。重启：`osascript -e 'tell application id "com.openai.codex" to quit'`，每 0.2 秒查一次是否还在运行（`… is running`，不需要自动化授权），最多等 `CCP_CHATGPT_QUIT_TIMEOUT` 秒（默认 15），退出后 `open -b com.openai.codex`。
   - 退出被拒（macOS 自动化授权，`(-1743)`）、超时、重新打开失败：档案照样已经切换，在 stderr 说明怎么手动完成（附可复制的 `ccp chatgpt use <名字> --restart`），退出码仍是 0。所以带 `--restart` 时 stderr 非空就表示桌面 App 没有重启，App 据此提示。
   - 桌面 App 在 `CODEX_HOME/packages/` 下的 `codex app-server` 守护进程退出后仍在运行；重启时是否一并停止旧档案的守护进程待真机实测，目前不停止。

### `ccp chatgpt rm <名字>`

1. 拒绝（都在询问之前，什么都不做，退出码 1；参数个数不对 2）：`default`；名字不合规或是保留名；当前档案（与 `ccp rm` 一样按是否同一个目录判断）；档案不存在（给出只差大小写的已有档案名）；`launchctl getenv CODEX_HOME` 等于档案目录（允许结尾多一个 `/`，或 `-ef` 为同一目录）——之后从 Dock 等打开的 ChatGPT 还会用它，提示 `ccp chatgpt use <当前档案>` 让 launchd 跟上；ccp 自己环境里的 `CODEX_HOME` 就是档案目录（在这个档案的 codex 会话里、或带着它的终端里运行——否则 ccp 和它启动的 `ps` 会把自己列为在用的进程），提示到新终端里重试；还有守护进程以外的进程在用这个档案（见第 2 条）；`launchctl` 失败或 `ps` 失败时无法确认，同样拒绝。
2. 在用这个档案的进程：`ps -A -E -ww -o pid= -o command=`（只调用一次）的每一行里，有 ` CODEX_HOME=<档案目录>`（或结尾多一个 `/`）后跟空格或行尾的进程（ccp 自己除外）。`-E` 把进程的环境以空格连接追加在命令行后面、不转义，所以按整行子串匹配，不拆分。系统自带的程序看不到环境，codex、ChatGPT 桌面 App 不是系统程序，看得到。分两类：
   - 守护进程：命令行里还有 ` app-server ` 这个参数（桌面 App 的 `codex app-server`），按第 3、4 条确认后停止。
   - 其他进程（ChatGPT 桌面 App 本身、`codex` 会话、在 launchd 指向这个档案期间从 Dock 等打开的程序……）：有任何一个就在询问之前拒绝，在 stderr 逐行列出 `PID <pid>  <命令名>`，请用户退出它们后重新执行；ccp 不停止它们，守护进程也不动。命令名是命令行第一个词的最后一段（路径里有空格时只取到第一个空格之前，只用于提示）。App 的"删除"不为此单独禁用：它在终端里运行同一条命令，拒绝信息显示在终端里。
3. 询问一次 `[y/N]`（只认 `y`/`yes`，读不到算否）；有守护进程时先在同一段提示里列出 PID、说明确认后会先停止它。
4. 停止守护进程：`kill -TERM`，每 0.2 秒检查一次，最多等 `CCP_CHATGPT_DAEMON_TIMEOUT` 秒（默认 10）；还在运行就不登出、不删除，不发 KILL。先停守护进程再登出，免得它在登出后又写回凭据。
5. `CODEX_HOME=<档案目录> command codex logout`（不经过包装函数，也不看 `CODEX_PROFILE`）。不看退出码：之后 `auth.json` 仍在（包括悬空的软链接）就不删除，说明原因；不在就 `/bin/rm -rf -- <档案目录>`（不带结尾的 `/`）：`rm` 不跟随软链接，共享项只删链接本身，`~/.codex` 里的内容不受影响；档案目录本身是软链接时也只删这个链接。

## codex 包装函数的行为

档案的决定顺序：

1. `CODEX_PROFILE` 非空：用它指定的档案（为空视同未设置），不管 `CODEX_HOME`。
2. 环境里有用户直接指定的 `CODEX_HOME`（即使为空）：原样调用 codex。
3. 否则用 ChatGPT 当前档案记录 `~/.codex-profiles/active`。

`CODEX_HOME` 等于 `~/.codex` 或位于 `~/.codex-profiles/` 之下（比较前转成绝对路径、去掉结尾的 `/`，不解析软链接）时，视为 cc-pilot 设置的——多半是从 launchd 继承来的旧值（从 Dock 打开的终端）——不算第 2 条，按第 3 条重设。解析出默认档案时去掉 `CODEX_HOME`（在子 shell 里 `unset` 后调用，用户 shell 里的变量不变；本来就没有时直接 `command codex`，与没装 cc-pilot 完全一样）；其他档案只对这一次调用设置 `CODEX_HOME=$HOME/.codex-profiles/<名字>`。档案不存在或名字不合规时报错、返回非零，不启动 codex。

## claude 包装函数的行为

档案的决定顺序：

1. 环境里已经设置了 `CLAUDE_CONFIG_DIR`（即使为空）：原样调用，不读当前档案记录，也不读 `CLAUDE_PROFILE`。
2. `CLAUDE_PROFILE` 非空：用它指定的档案。为空视同未设置。
3. 否则用当前档案记录 `~/.claude-profiles/active`（只取第一行，去掉首尾空白）。记录不存在、为空或为 `default` 时是默认档案。

解析出默认档案时不设置 `CLAUDE_CONFIG_DIR`；其他档案只对这一次调用设置 `CLAUDE_CONFIG_DIR=$HOME/.claude-profiles/<名字>`（绝对路径，不含 `~`，结尾不带 `/`）。名字不符合 `^[A-Za-z0-9][A-Za-z0-9._-]*$`，或者档案目录不存在时，报错并给出修复建议，返回非零，不回退到默认档案。

## 状态栏转发（实时额度，ADR 0004）

解析出档案之后（默认档案也一样），包装函数在用户参数**前面**加一个覆盖（`_ccp_statusline_override`）：

```
--settings '{"statusLine":{"type":"command","command":"<安装目录>/bin/ccp statusline <档案名>"}}'
```

ccp 的路径先按 sh 引用（只在需要时加引号），再按 JSON 字符串转义。不改任何 `settings.json`。以下情况不加：

- 环境里已有 `CLAUDE_CONFIG_DIR`（与档案规则 1 一致，原样调用）；
- 用户自己传了 `--settings`（参数恰好是 `--settings` 或以 `--settings=` 开头）；
- 开关关闭：`~/.claude-profiles/.live-quota/disabled` 存在（App 设置菜单写它；不存在即开启）。

实测（Claude Code 2.1.310，用临时 `CLAUDE_CONFIG_DIR`，以 `env` 设置为探针）：

- `--settings` 与各级 `settings.json` **逐字段深合并**（Claude Code 内部是 lodash `mergeWith`）：只换掉 `statusLine.type` 和 `statusLine.command`，用户的 `padding` 等字段照常生效。优先级是 user < project < local < `--settings` < 托管设置。
- 传两个 `--settings` 时**只有最后一个生效**，前一个整个被丢弃，不合并。所以用户传了 `--settings` 时包装函数不加覆盖，用户的设置优先，这次会话没有实时额度。
- 前面加了 `--settings` 后，`claude --version`、`claude mcp list`、`claude update --help`、`claude doctor --help` 都照常工作；未登录时 `claude -p` 的输出与不加完全相同（`-p` 本来就不运行状态栏）。所以子命令不需要特殊处理。
- 以 `{` 开头、`}` 结尾的值按内联 JSON 处理：Claude Code 把它写进一个临时的 `claude-settings-*.json`，之后与 `--settings <文件>` 走同一条路径（读源码确认；其中的同意检查只针对 attribution 相关字段，不涉及 `statusLine`）。真实交互式会话里状态栏确实被替换，留给人工验收确认。
- 用户没有配置状态栏时，覆盖会让 Claude Code 运行一个什么都不输出的状态栏命令。

`ccp statusline <档案名>`（`lib/cmd-statusline.zsh`，不列在用法说明里）由 Claude Code 在每次刷新状态栏时运行（`sh -c`，工作目录是会话的当前目录，状态栏 JSON 从标准输入给出）：

1. 把标准输入原样（不在 shell 里解析）写进 `~/.claude-profiles/.live-quota/<档案名>.json`，默认档案是 `default.json`。内容是（status 原样嵌入，原始 JSON 里的换行也保留，不保证只有一行）：`{"profile":"<档案名>","received_at":<Unix 秒，三位小数>,"status":<原始状态栏 JSON>}`。先写同目录的 `.<档案名>.json.<pid>`，再 rename 原子替换；读的时候忽略以 `.` 开头的文件。标准输入不以 `{` 开头（例如为空）时不写。档案名不合规时什么都不做。
2. 找出原本生效的状态栏命令：依次查 `<project_dir>/.claude/settings.local.json`、`<project_dir>/.claude/settings.json`、档案自己的 `settings.json`（默认档案是 `~/.claude/settings.json`），`project_dir` 取状态栏 JSON 的 `workspace.project_dir`，取第一个有非空 `statusLine.command` 的。字段用 `/usr/bin/plutil -extract … raw` 读，不依赖 jq。每次运行都重新读，所以在会话里用 `/statusline` 改过的设置照常生效。
3. 把标准输入逐字节交给它（`/bin/sh -c`，`~` 等写法照常展开），原样输出它的标准输出，退出码也用它的；都没配置时什么都不输出。

不能拖慢状态栏：写文件只用 zsh 内建（`zsh/files`、`zsh/datetime`），失败静默忽略，不联网。原状态栏命令运行时环境里有 `_CCP_STATUSLINE_FORWARDING=1`，嵌套运行的 `ccp statusline` 见到它就什么都不做，避免状态栏命令指回自己时无限递归。

## ccp add 建立的档案

`ccp add <名字>` 在 `~/.claude-profiles/<名字>/` 里只放四类东西：

- 共享资源的软链接：`CLAUDE.md`、`skills`、`agents`、`commands`、`plugins`、`projects`，各自指向 `~/.claude/` 中的同名项（绝对路径；默认档案里还没有的项也照建）。清单和建立方式集中在 `cmd-add.zsh` 的 `_ccp_shared_resources` / `_ccp_share_resources`。
- `settings.json`：默认档案 `~/.claude/settings.json` 的副本（普通文件，之后各改各的，见 ADR 0003）。默认档案没有这个文件时不写；复制失败时不写，只给出提示。
- `.claude.json`：只含默认档案 `~/.claude.json`（不在 `~/.claude/` 里）的 `mcpServers` 和 `projects` 两个字段，用 JXA 原样复制。默认档案的 `.claude.json` 不存在或无法解析时不写这个文件，只给出提示。
- `.ccp-workdir/`：启动 Claude Code 用的空目录（见下面"启动 Claude Code 的工作目录"）。

然后以 `CLAUDE_CONFIG_DIR=<档案目录>` 直接启动 `claude`（不经过包装函数，也不看 `CLAUDE_PROFILE`），不改变当前档案。

## 启动 Claude Code 的工作目录（`ccp add` / `ccp rm`）

两者都通过 `lib/launch.zsh` 的 `_ccp_launch_profile_claude` 启动 `claude`：在子 shell 里 cd 到 `<档案目录>/.ccp-workdir`（不存在时建立，只建这一层）再启动，调用者的当前目录不变。不在调用者的当前目录启动，是因为：

- Claude Code 第一次在某个目录里启动时会询问是否信任它（"Accessing workspace"，默认选项是退出），结果按绝对路径记在**各档案自己的** `.claude.json` 的 `projects` 里。新档案没有信任过调用者的目录（App 打开的终端里是 `~`）；在 `~` 下这个询问每次都会出现，还会把 `~/.claude/settings.json` 当作项目设置，提示预先批准其中的工具权限。误选退出就中断了 add / rm。
- 路径固定，所以用户在 `ccp add` 里对它选过一次"信任"，同一档案之后的 `ccp rm` 不会再问。启动前的提示语说明这是 ccp 专用的空目录，可以放心选 Yes。
- 目录是空的：没有项目设置、`CLAUDE.md` 或可供读取的文件。
- 放在档案目录里：不在 `~` 或档案目录之外留下文件，`ccp rm` 删除档案时一并删除。系统临时目录则会让信任落在一个与 ccp 无关、其他程序也在写入的目录上。

工作目录建立失败时报错，不启动 `claude`；`ccp rm` 照常做钥匙串检查（能否删除只由它决定）。

## ccp rm 的删除条件

`ccp rm <名字>` 先拒绝默认档案、当前档案、不合规或不存在的档案；然后请用户确认，以 `CLAUDE_CONFIG_DIR=<档案目录>` 在档案的 `.ccp-workdir` 里启动 `claude` 让用户 `/logout`，再用 `security find-generic-password -s <service 名>`（不带 `-w`）检查钥匙串项。只有退出码 44（钥匙串项不存在）才删除档案目录；还在（0）或查询失败（其他退出码）都拒绝删除。

## service 名的跨端一致性

`_ccp_service_name [配置目录]`：不带参数时返回 `Claude Code-credentials`（默认档案）；带参数时对原始字符串做 NFC 规范化后取 sha256 前 8 位。App 核心应对 `tests/fixtures/service-names.tsv` 的每一行得到相同结果，也可以直接调用 shell 函数比较：

```
zsh -f -c 'source "$1" && _ccp_service_name "${@:2}"' _ <仓库>/shell/lib/keychain.zsh [配置目录]
```
