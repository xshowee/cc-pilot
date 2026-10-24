# settings.json 每个档案一份

新建档案时，把默认档案的 `settings.json` 复制一份作为新档案自己的 `settings.json`，之后各档案各改各的；它不再是共享资源。原因是不同档案的账号可能处在不同的订阅等级，而 Claude Code 把跟等级有关的设置（`advisorModel`、`model`）和个人偏好写在同一个文件里：共用时，在 Pro 账号里执行 `/advisor opus`，会写进共享文件，Max 账号也跟着变成 opus。实测 Claude Code 2.1.310 在等级不够时会静默跳过不可用的 advisor（`Skipping advisor - claude-fable-5-1 is not a valid advisor model`），不报错，所以这个问题平时看不出来。

## Considered Options

- **继续共用，按档案叠加覆盖**：由 `claude` 包装函数在档案目录里有覆盖文件时追加 `--settings <文件>`。实测能覆盖 `advisorModel`，也不碰共享文件。没有采用：`/advisor`、`/model` 依然写进共享的 `userSettings`，在低等级档案里用命令改模型仍会影响其他档案，只能靠"别在会话里用命令改"的约定兜底。
- **共享资源保持软链接，什么都不改**：多数用户的几个账号等级相同，共用零成本；但对等级不同的账号，上面的问题无法避免。

## Consequences

- 偏好类设置（主题、状态栏、语言、hooks、env 等）不再同步：在一个档案里改了，其他档案要各自再改。
- `plugins/` 仍然共享，`enabledPlugins` 却在各自的 `settings.json` 里：在一个档案里安装并启用的插件，在其他档案里显示为已安装但未启用，需要各自启用一次。
- 默认档案没有 `settings.json` 时，新档案也没有，由 Claude Code 第一次写设置时自己创建。
- 已有档案的 `settings.json` 仍是软链接，cc-pilot 不自动迁移（只会用一次的逻辑不值得常驻在包装函数里）。
