# Issue tracker：本地 Markdown

本仓库的 issue 和 spec 以 markdown 文件形式存放在 `.scratch/` 中。

## 约定

- 每个 feature 一个目录：`.scratch/<feature-slug>/`
- spec 文件为 `.scratch/<feature-slug>/spec.md`
- 实现类 issue 每个 ticket 一个文件，路径为 `.scratch/<feature-slug>/issues/<NN>-<slug>.md`，从 `01` 开始编号；不要把所有 ticket 合并到一个文件里
- 分诊状态记录在每个 issue 文件顶部附近的 `Status:` 行中（角色字符串见 `triage-labels.md`）
- 评论和讨论记录追加到文件末尾的 `## Comments` 标题下

## 当 skill 要求 "publish to the issue tracker" 时

在 `.scratch/<feature-slug>/` 下新建文件（目录不存在则先创建）。

## 当 skill 要求 "fetch the relevant ticket" 时

读取所引用路径下的文件。用户通常会直接给出路径或 issue 编号。

## Wayfinding 操作

供 `/wayfinder` 使用。**map** 是一个文件，每个 ticket 对应一个 **child** 文件。

- **Map**：`.scratch/<effort>/map.md`（包含 Notes / Decisions-so-far / Fog 正文）。
- **Child ticket**：`.scratch/<effort>/issues/NN-<slug>.md`，从 `01` 开始编号，正文写问题。用 `Type:` 行记录 ticket 类型（`research`/`prototype`/`grilling`/`task`）；用 `Status:` 行记录 `claimed`/`resolved`。
- **Blocking**：在顶部附近写一行 `Blocked by: NN, NN`。当其列出的所有文件都为 `resolved` 时，该 ticket 即解除阻塞。
- **Frontier**：扫描 `.scratch/<effort>/issues/`，找出未关闭、未阻塞且未被认领的文件；编号最小的优先。
- **Claim**：在开始任何工作之前，先设置 `Status: claimed` 并保存。
- **Resolve**：在 `## Answer` 标题下追加答案，设置 `Status: resolved`，然后在 `map.md` 的 Decisions-so-far 中追加一条上下文指引（要点 + 链接）。
