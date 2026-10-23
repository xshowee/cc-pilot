# CC Pilot

[English](README.md) | 简体中文

在同一台 Mac 上，于自己的多个 Claude Code 订阅账号之间切换，并在菜单栏查看每个账号的剩余额度。

> **声明**：cc-pilot 是独立的开源项目，与 Anthropic 没有任何关联，也未获得其认可或支持。
> 你用 cc-pilot 管理的每一个账号都应当属于你本人。cc-pilot 不能用来与他人共享账号，
> 也不能用来规避单个账号的用量限制。

## 它能做什么

在 Claude Code 里切换账号，原本只能先 `/logout` 再 `/login`：每次都要走浏览器授权，原来那个账号在这台机器上的登录也随之失效，不同终端也没法同时用不同账号。

cc-pilot 为每个账号准备一个独立的**档案**：

- **档案之间登录互不影响**。每个档案有自己的登录状态，切来切去不需要重新登录。
- **切换只影响之后新启动的会话**。已经在运行的 Claude Code 一直使用它启动时的档案，所以不同终端可以同时使用不同账号。
- **单个终端临时用别的档案**：`CLAUDE_PROFILE=work claude`，不改变当前档案。
- **工作环境共用**。设置、`CLAUDE.md`、技能、子代理、自定义命令、插件和项目会话历史由所有档案共用；输入框的历史记录（按 ↑ 调出的那些）每个档案各有一份。
- **原来的环境就是默认档案**。你现在的 `~/.claude` 原样保留，名叫 `default`，不需要迁移。
- **从不自动切换**。切换永远由你手动触发。

提供两个完全平等的入口：

- **命令行工具 `ccp`**：管理档案、切换当前档案。
- **菜单栏 App CC Pilot**：能做 `ccp` 做的事，还能在你点击刷新时显示每个账号的额度。

### 菜单栏 App

- 菜单栏显示两行：当前档案名，以及这个档案所在账号的 5 小时窗口剩余额度（从未刷新过时显示"—"）。也可以设置为只显示一个图标。
- 面板里列出所有档案：以登录账号的邮箱为主要显示内容，档案名作为副标题，另外显示组织和订阅等级。还没登录的显示"未登录"；两个档案登录的是同一个账号时，会标注"与某某是同一账号"。
- 点一下即可切换当前档案，效果与 `ccp use` 完全相同。添加和删除档案时，App 打开"终端"执行 `ccp add` / `ccp rm`，流程与命令行完全一致。在 `ccp` 里做的修改会立刻反映到 App 上。
- 额度：点"刷新全部"或某个账号旁边的刷新按钮，获取 5 小时窗口和覆盖全部模型的周窗口的**剩余**百分比及重置时间；展开账号可以看到按模型细分的周窗口和超额付费的使用情况。
  - 所有数字都是剩余百分比，不是 Claude Code `/usage` 里的已用百分比。
  - 颜色只取自服务端给出的严重程度，服务端没给就不着色。
  - 每个数字都标明获取时间，超过 30 分钟变灰；已经过了重置时间的窗口显示"已重置，待刷新"。
  - 登录同一个账号的多个档案刷新时只请求一次。
  - 短期凭据过期的档案显示**待续期**：打开一次该档案的 `claude` 即可恢复（App 不发请求，也不替你续期）；凭据已无法续期的显示**需重新登录**。
- 界面根据系统语言显示中文或英文。只出现在菜单栏，没有 Dock 图标。"登录时启动"可选，默认关闭。

## 联网与隐私

CC Pilot 只访问下面两个地址：

| 地址 | 什么时候访问 |
| --- | --- |
| 额度接口 `https://api.anthropic.com/api/oauth/usage` | **只在你点击**"刷新全部"或某个账号的刷新按钮时。启动 App、打开面板、切换档案都不会请求。请求头如实标明 `User-Agent: cc-pilot/<版本>`，不冒充官方客户端。 |
| 更新检查地址 `https://raw.githubusercontent.com/xshowee/cc-pilot/main/appcast.xml` | 由 [Sparkle](https://sparkle-project.org) 访问：开启"自动检查更新"（默认开启）时每天检查一次，距上次检查已满一天时会在 App 启动后不久检查；点"检查更新…"时立即检查。请求不附带系统信息。 |

确认安装更新后，Sparkle 从本仓库的 GitHub Releases 下载新版本的 DMG。不想自动检查，可以在面板左下角的齿轮菜单里关掉"自动检查更新"。

- **不收集任何使用数据**，不上报崩溃信息，没有任何统计或分析代码。
- **凭据只读**。App 通过系统自带的 `/usr/bin/security` 读取钥匙串里 Claude Code 存的凭据，只在单次请求期间保存在内存里，从不写进日志、缓存文件或错误信息。cc-pilot **从不写入、从不删除、也从不续期**凭据：续期始终由 Claude Code 自己完成，登出由你在 Claude Code 里执行 `/logout`。
- `ccp` 不读取凭据。唯一与钥匙串有关的是 `ccp rm`：它只检查该档案的钥匙串项是否还存在，不读取内容。
- 读取凭据不应该弹出钥匙串授权窗口。如果哪天出现了弹窗，请不要点"允许"：这说明 cc-pilot 与当前的 Claude Code 版本不兼容，App 也会这样提示你。

## 它会碰哪些东西

| 位置 | cc-pilot 做什么 |
| --- | --- |
| `~/.zshrc` | 征得你的同意后，在末尾加**一行**（见下面"安装"）。执行多次也只有一行；卸载时只删除这一行。其余内容一个字节都不动。 |
| `~/.cc-pilot/` | `ccp` 命令和 `claude` 包装函数的安装位置，由 App 安装和更新。 |
| `~/.claude-profiles/` | 除默认档案以外的档案，每个档案一个目录：`~/.claude-profiles/<名字>/`；以及记录当前档案的文件 `~/.claude-profiles/active`。 |
| `~/.claude/`、`~/.claude.json`（默认档案） | **只读**。新建档案时，从 `~/.claude.json` 复制 MCP 服务器和项目信任设置；新档案里的共享资源是指向 `~/.claude/` 的软链接；App 从 `.claude.json` 读取账号资料（邮箱、组织、订阅等级）用于显示。 |
| 钥匙串 | **只读**，见上面"联网与隐私"。 |
| "终端" | 在 App 里添加或删除档案时，App 打开一个新的终端窗口执行 `ccp add` / `ccp rm`。第一次会由 macOS 询问是否允许 CC Pilot 控制"终端"；不允许也没关系，App 会给出命令让你自己复制执行。 |

cc-pilot **不会**：

- 修改或替换 Claude Code 的可执行文件。包装函数用 `command claude` 调用真正的 Claude Code，Claude Code 的自动更新照常进行。
- 修改默认档案的任何内容，或者迁移它。
- 影响 `~/.zshrc` 里你已有的其他 Claude Code 包装函数或别名。
- 在只有默认档案、或者当前档案就是默认档案时改变 `claude` 的任何行为：这时它和接入之前完全一样。

注意，共享资源是软链接，所以在任何一个档案里由 Claude Code 修改设置（比如执行 `/model`）、安装技能或插件，改的都是 `~/.claude/` 里的那一份，所有档案同时生效。

## 系统要求

- macOS 13 或更高版本，同时支持 Apple Silicon 和 Intel。
- zsh（macOS 的默认 shell）。
- 已经安装 Claude Code，并且在 zsh 里能直接执行 `claude`。

## 安装

1. 从 [GitHub Releases](https://github.com/xshowee/cc-pilot/releases/latest) 下载 `CCPilot-<版本>.dmg`。App 使用 Developer ID 签名，并已通过 Apple 公证。
2. 打开 DMG，把 CC Pilot 拖进"应用程序"文件夹，然后打开它。
3. 首次运行时，App 会说明并询问是否接入 zsh。选择"添加到 ~/.zshrc"后，App 把 `ccp` 和 `claude` 包装函数安装到 `~/.cc-pilot/`，再在 `~/.zshrc` 末尾加上这一行：

   ```zsh
   source "$HOME/.cc-pilot/cc-pilot.zsh"  # cc-pilot
   ```

   选"暂不"则不修改任何文件，之后可以从面板左下角的齿轮菜单 › "接入 zsh…"重新开始。
4. 新开一个终端窗口（已打开的终端可以执行 `source ~/.zshrc`），`ccp` 就可以用了。

以后 App 每次更新，都会把 `~/.cc-pilot/` 更新到新版本，不再询问，也不再改 `~/.zshrc`。

**不装 App、只用命令行**：把本仓库的 `shell/` 目录复制为 `~/.cc-pilot/`，然后执行 `~/.cc-pilot/bin/ccp init`。它会先列出要加的那一行并询问，回答 `y` 才写入。

## 上手

```zsh
ccp add work        # 新建档案 work，并直接进入它的 Claude Code 完成首次引导和登录，完成后退出
ccp use work        # 切换：之后新启动的 claude 使用 work
claude              # 新开的终端里，这就是 work 账号
ccp use default     # 切回原来的环境

CLAUDE_PROFILE=work claude   # 只在这一次、这个终端里临时使用 work，不改变当前档案
```

新档案第一次启动时，会经历 Claude Code 自带的首次引导和登录流程，就像全新安装一样。新档案只登录了它自己的账号，默认档案的登录不受影响。

`claude` 决定使用哪个档案时，按以下优先级从高到低判断：

1. 环境里已经设置了 `CLAUDE_CONFIG_DIR`：cc-pilot 完全不干预，原样调用 Claude Code。
2. 设置了 `CLAUDE_PROFILE`：使用它指定的档案。
3. 否则使用当前档案。

当前档案指向一个已经不存在的档案时，`claude` 会报错并告诉你怎么修复，不会悄悄改用默认档案，以免在不知情时消耗错误账号的额度。

## `ccp` 命令

| 命令 | 作用 |
| --- | --- |
| `ccp ls` | 列出所有档案，当前档案前面标 `*`。第一行总是 `default`。 |
| `ccp current` | 只输出当前档案的名字，方便在脚本或提示符里使用。只看当前档案，不看 `CLAUDE_PROFILE`。 |
| `ccp use <名字>` | 切换当前档案；`ccp use default` 切回默认档案。只影响之后新启动的会话。 |
| `ccp add <名字>` | 新建档案，并直接进入它的 Claude Code 完成首次引导和登录。不改变当前档案。Claude Code 在档案目录里的专用空目录 `.ccp-workdir` 中启动，而不是在你的当前目录；如果它询问是否信任这个目录，放心选 Yes，之后对这个档案执行 `ccp rm` 时不会再问。 |
| `ccp rm <名字>` | 删除档案：先请你确认，然后打开该档案的 Claude Code，请你在里面执行 `/logout` 并退出；确认已经登出后才删除。默认档案和当前档案不能删除。Claude Code 同样在档案的 `.ccp-workdir` 中启动，删除档案时一并删除。 |
| `ccp init [--yes]` | 接入 zsh：征得同意后在 `~/.zshrc` 末尾加上接入行；`--yes` 不询问。已经接入时什么都不改。 |
| `ccp uninstall` | 从 `~/.zshrc` 里删除 `ccp init` 加的那一行，其他内容不动。 |

档案名只能由字母、数字、`.`、`_` 和 `-` 组成，并且以字母或数字开头；`default` 和 `active` 是保留名。

## 已知局限

- **哪些入口不会跟着切换**：切换靠的是 zsh 里的 `claude` 包装函数，所以不经过它启动的 Claude Code 不受切换影响，始终使用默认档案。包括：
  - IDE 插件（比如 VS Code、JetBrains 里的 Claude Code）；
  - Claude Desktop；
  - zsh 以外的 shell（bash、fish 等）。
- **MCP 服务器和项目信任设置只在创建时复制一次**。`ccp add` 从默认档案的 `~/.claude.json` 里只复制 `mcpServers`（用户级 MCP 服务器）和 `projects`（项目信任设置）两项，作为新档案的初始值。之后各档案各自独立变化，不会保持同步：在默认档案里新加的 MCP 服务器，不会出现在已经建好的档案里，反之亦然。claude.ai 账号里配置的连接器跟账号走，不在复制范围内。
- **档案不能改名**。钥匙串里存凭据的那一项，名字是由档案目录的路径算出来的，改名就会丢失登录状态。想换名字，正确的做法是：用新名字 `ccp add` 新建一个档案并登录，再用 `ccp rm` 删除旧档案（删除时会引导你先登出）。
- **依赖 Claude Code 的内部实现**。钥匙串项的命名方式、`.claude.json` 里账号资料的结构、额度接口的地址和字段都没有官方文档，是按 Claude Code 2.1.309 的实际行为实现的。Claude Code 更新后如果不再兼容，App 会提示"与当前 Claude Code 版本不兼容"或"接口可能已变化，请更新 cc-pilot"，而不是显示猜出来的数字。
- 使用 API key 或 `setup-token` 生成的长期 token 登录时，不支持额度显示。

## 卸载

1. （可选）如果不再需要那些档案，先用 `ccp use default` 切回默认档案，再用 `ccp rm <名字>` 逐个删除（当前档案不能删除）。这样每个档案都会先登出，钥匙串里不会留下仍然有效的凭据。
2. 执行 `ccp uninstall`（或者在面板左下角的齿轮菜单 › "移除 zsh 接入…"），删除 `~/.zshrc` 里的接入行。
3. 退出 CC Pilot，把它从"应用程序"文件夹删除。

默认档案（`~/.claude`、`~/.claude.json` 和它的登录）始终不受影响。卸载之后，新开的终端里 `claude` 的行为与安装 cc-pilot 之前完全一样。

如果想把痕迹清理干净，还可以手动删除：

- `~/.cc-pilot/`：`ccp` 和包装函数（`ccp uninstall` 保留它）；
- `~/.claude-profiles/`：其余档案和当前档案记录。没有先 `ccp rm` 就直接删除时，这些档案的凭据还留在钥匙串里（名为 `Claude Code-credentials-` 加 8 位十六进制的项），可以用"钥匙串访问"删除；
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
Sources/Core/   App 核心：档案、切换、凭据读取、额度获取与解析（不含界面）
Sources/App/    SwiftUI 菜单栏界面
Resources/      Info.plist、本地化字符串、entitlements
tests/          shell 黑盒测试、App 核心的检查程序、假的 claude / security
docs/           设计决策（docs/adr/）与发布流程（docs/release.md）
```

术语见 [GLOSSARY.md](GLOSSARY.md)，设计决策见 [docs/adr/](docs/adr/)，签名、公证和发布流程见 [docs/release.md](docs/release.md)。

## 许可证

[MIT](LICENSE)
