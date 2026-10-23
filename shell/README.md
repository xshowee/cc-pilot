# cc-pilot 的 shell 部分

## 安装布局

本目录与安装后的 `~/.cc-pilot/` 一一对应，**安装就是把本目录原样复制过去**（`ccp`、App 安装器都按这个布局）：

```
~/.cc-pilot/
├── cc-pilot.zsh        入口：被 ~/.zshrc source；定义 claude 包装函数，把 bin/ 加到 PATH 最前面
├── bin/ccp             命令行工具（可执行，#!/bin/zsh -f）
└── lib/
    ├── profiles.zsh    共享库：档案目录、当前档案记录、档案名规则、档案解析
    ├── keychain.zsh    共享库：钥匙串 service 名计算 _ccp_service_name
    ├── zshrc.zsh       共享库（只给 ccp 用）：~/.zshrc 的接入行与读写辅助
    └── cmd-<命令>.zsh  ccp 每个子命令一个文件，定义 _ccp_cmd_<命令>
```

- 安装根目录固定为 `~/.cc-pilot/`，不能放在 `~/.claude-profiles/` 下（那里的每个目录都会被当成档案）。
- 接入 zsh 就是在 `~/.zshrc` 里加一行 source（由 `ccp init` 写入，见下面"接入 zsh"）。
- `cc-pilot.zsh` 和 `bin/ccp` 都按自身所在位置找 `lib/`，所以直接 source 仓库里的 `shell/cc-pilot.zsh` 也能用；测试就是把本目录复制到临时 HOME 的 `.cc-pilot/` 再运行。

## 代码约定

- `cc-pilot.zsh` 只 source `lib/profiles.zsh`；`bin/ccp` source `lib/` 下所有不以 `cmd-` 开头的 `.zsh` 文件，再只 source 被调用的那个 `cmd-<命令>.zsh`。新增共享库直接放进 `lib/` 即可。
- `lib/` 里的代码会进入用户的交互 shell：只定义 `_ccp_` 开头的函数，不定义全局变量；函数开头写 `emulate -L zsh`；出错只 `return`，不 `exit`。
- 系统工具用绝对路径（`/usr/bin/osascript`、`/usr/bin/shasum`）；`claude` 和 `security` 按 PATH 查找，测试会在 PATH 最前面放假程序。

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

`ccp ls` 第一行总是 `default`，之后按字节序列出 `~/.claude-profiles/` 下名字合规的目录（含指向目录的软链接）；当前档案前面是 `* `，其他是两个空格。`ccp current` 只看当前档案记录，不看 `CLAUDE_PROFILE`。

## claude 包装函数的行为

档案的决定顺序：

1. 环境里已经设置了 `CLAUDE_CONFIG_DIR`（即使为空）：原样调用，不读当前档案记录，也不读 `CLAUDE_PROFILE`。
2. `CLAUDE_PROFILE` 非空：用它指定的档案。为空视同未设置。
3. 否则用当前档案记录 `~/.claude-profiles/active`（只取第一行，去掉首尾空白）。记录不存在、为空或为 `default` 时是默认档案。

解析出默认档案时不设置 `CLAUDE_CONFIG_DIR`；其他档案只对这一次调用设置 `CLAUDE_CONFIG_DIR=$HOME/.claude-profiles/<名字>`（绝对路径，不含 `~`，结尾不带 `/`）。名字不符合 `^[A-Za-z0-9][A-Za-z0-9._-]*$`，或者档案目录不存在时，报错并给出修复建议，返回非零，不回退到默认档案。

## ccp add 建立的档案

`ccp add <名字>` 在 `~/.claude-profiles/<名字>/` 里只放两类东西：

- 共享资源的软链接：`settings.json`、`CLAUDE.md`、`skills`、`agents`、`commands`、`plugins`、`projects`，各自指向 `~/.claude/` 中的同名项（绝对路径；默认档案里还没有的项也照建）。清单和建立方式集中在 `cmd-add.zsh` 的 `_ccp_shared_resources` / `_ccp_share_resources`，单个文件改用复制时只改这两个函数。
- `.claude.json`：只含默认档案 `~/.claude.json`（不在 `~/.claude/` 里）的 `mcpServers` 和 `projects` 两个字段，用 JXA 原样复制。默认档案的 `.claude.json` 不存在或无法解析时不写这个文件，只给出提示。

然后以 `CLAUDE_CONFIG_DIR=<档案目录>` 直接启动 `claude`（不经过包装函数，也不看 `CLAUDE_PROFILE`），不改变当前档案。

## ccp rm 的删除条件

`ccp rm <名字>` 先拒绝默认档案、当前档案、不合规或不存在的档案；然后请用户确认，以 `CLAUDE_CONFIG_DIR=<档案目录>` 启动 `claude` 让用户 `/logout`，再用 `security find-generic-password -s <service 名>`（不带 `-w`）检查钥匙串项。只有退出码 44（钥匙串项不存在）才删除档案目录；还在（0）或查询失败（其他退出码）都拒绝删除。

## service 名的跨端一致性

`_ccp_service_name [配置目录]`：不带参数时返回 `Claude Code-credentials`（默认档案）；带参数时对原始字符串做 NFC 规范化后取 sha256 前 8 位。App 核心应对 `tests/fixtures/service-names.tsv` 的每一行得到相同结果，也可以直接调用 shell 函数比较：

```
zsh -f -c 'source "$1" && _ccp_service_name "${@:2}"' _ <仓库>/shell/lib/keychain.zsh [配置目录]
```
