# ChatGPT 档案共享会话：sqlite_home 指向默认档案，会话目录软链接

ChatGPT 档案之间共享会话历史，做法是：新建档案时在它自己的 `config.toml` 里写入 `sqlite_home = "<绝对路径>/.codex"`，并把 `sessions/`、`archived_sessions/`、`thread-writer-locks/`、`.tmp/` 做成指向 `~/.codex` 下同名目录的软链接。原因是 Codex 的会话列表来自 `state_5.sqlite` 的 `threads` 表（桌面 App 只读数据库，`codex resume` 也优先读数据库），只共享会话文件时其他档案的列表里看不到；而 `sqlite_home` 是 Codex 支持的配置项，数据库路径为 `<sqlite_home>/<文件名>`，未设置时为 `CODEX_HOME`（openai/codex `core/src/config/mod.rs`、`state/src/sqlite.rs`）。

## Considered Options

- **只软链接 `sessions/`**：其他档案的数据库不知道这些会话，桌面 App 看不到；各档案的写入锁互不相干，一个档案可能压缩另一个档案正在写的会话记录。
- **软链接单个 sqlite 文件**：`-wal`/`-shm` 会跟随软链接，但数据库损坏时 Codex 会把这个路径改名备份，软链接被移走后该档案悄悄换用一份新的、不共享的数据库。
- **不共享会话**：最简单，但与 Claude Code 档案共享会话历史的体验不一致。

## Consequences

- `sqlite_home` 一次挪动全部数据库（state、thread_history、logs、goals、memories、queue），记忆、目标等也随之共享。
- 其他档案会写入 `~/.codex`，与 Claude Code 档案经软链接写入 `~/.claude/` 是同一类情况，README 的"只读"说明要相应修正。
- 不共享：`auth.json`、`installation_id`、`.codex-global-state.json`（含推送 token；桌面侧边栏的会话分组和标题也存在这里，共享会话在其他档案里可能不带分组）、`config.toml`（新建时复制，之后各改各的，同 ADR 0003）、`history.jsonl`（用于会话归属，同 Claude Code 的输入历史）。共享：`AGENTS.md`、`skills/`、`plugins/`、`rules/`。
- 桌面 App 另有自己的 `CODEX_HOME/sqlite/codex.db`（含 `local_thread_catalog`），不受 `sqlite_home` 影响，每个档案一份；2026-11-04 真机实测，它会从共享的数据库同步出其他档案新建的本地会话，不需要共享。
- 只有本地的 Codex 会话被共享；桌面 App 里的普通聊天存在云端、跟账号走，天然按账号隔离。
- 写入锁共享后，同一会话被另一个进程（例如 Zed 里的 codex）打开时，其他档案只能查看、不能继续，与不装 cc-pilot 时在同一档案里的行为一致。
- 上游 Codex 正在给新会话标记所属账号，CLI 将默认只列出当前账号的会话。届时 `codex resume` 看不到其他账号的会话，cc-pilot 接受这一点，不去绕过。
- 会话记录只有一份，统计 Token 用量和读取实时额度时只扫 `~/.codex/sessions/` 和 `archived_sessions/` 一次，不按档案重复扫描。
