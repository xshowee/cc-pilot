// Token 用量账本的 ChatGPT 部分（chatgpt-profiles ticket 09）。表结构见 TokenLedger.swift 文件头。
//
// 迁移（v5）：只加不改。messages 加 tool 列（旧明细默认 claudeCode），新建 chatgpt_files 与 chatgpt_sessions；
// Claude 的明细、汇总、起算点、读取位置原样保留，不重读 Claude 的会话记录。
// daily 不加工具维度：已归属的账号键自带前缀（"chatgpt:"），两个工具不会相撞；只有未归属的汇总（account 为空串）
// 两个工具合在一起，它不显示（cumulativeUsage(account: nil) 只用于检查）。

import Foundation

extension TokenLedger {
    func migrateToVersion5() throws {
        try db.transaction {
            try db.execute("""
                ALTER TABLE messages ADD COLUMN tool TEXT NOT NULL DEFAULT '\(Tool.claudeCode.rawValue)';
                CREATE TABLE chatgpt_files (path TEXT PRIMARY KEY, cursor TEXT NOT NULL) WITHOUT ROWID;
                CREATE TABLE chatgpt_sessions (
                    session_id TEXT PRIMARY KEY,
                    creator_user_id TEXT,
                    parent_session_id TEXT,
                    profile TEXT,
                    observed_at REAL
                ) WITHOUT ROWID;
                PRAGMA user_version = 5;
                """)
        }
    }
}

// MARK: - 读入（会话记录读取器的扫描结果）

extension TokenLedger {
    /// 账本里记着的 ChatGPT 会话记录读取位置：交给 CodexSessionReader.scan，从上次读到的地方接着读
    func chatgptCursors() throws -> [String: CodexFileCursor] {
        if let cached = chatgptCursorCache { return cached }
        let statement = try db.prepare("SELECT path, cursor FROM chatgpt_files")
        let decoder = JSONDecoder()
        var cursors: [String: CodexFileCursor] = [:]
        while try statement.step() {
            // 解不开的位置当作没读过：从头读，靠去重键不重复计入
            guard let path = statement.text(0), let json = statement.text(1),
                  let cursor = try? decoder.decode(CodexFileCursor.self, from: Data(json.utf8)) else { continue }
            cursors[path] = cursor
        }
        chatgptCursorCache = cursors
        return cursors
    }

    /// 记入一次扫描：新的 token_count 事件（每个一条明细，待归属）、会话的 session_meta、读完之后的位置，
    /// 在同一个事务里写入（中途退出不会重复计入或漏记）。返回新记入的明细数。
    ///
    /// 每个事件按 info.last_token_usage 记（不累加 total_token_usage），四类映射见 TokenCounts(codex:)；
    /// info 为 null（只带 rate_limits）的不记。message_id 是事件的去重键（CodexSessionLog.swift 文件头）：
    /// resume、fork 重放到别的文件里的同一事件只记一次；已汇总的、早于 forgotten_before 的同 Claude 规则跳过。
    @discardableResult
    func ingest(chatgpt scan: CodexSessionScan) throws -> Int {
        let previous = try chatgptCursors()
        let changed = scan.cursors.filter { previous[$0.key] != $0.value }
        let gone = previous.keys.filter { scan.cursors[$0] == nil }
        let events = scan.events.filter { $0.usage != nil }
        guard !changed.isEmpty || !gone.isEmpty || !events.isEmpty || !scan.sessions.isEmpty else { return 0 }
        let added = try db.transaction { () -> Int in
            let insert = try db.prepare("""
                INSERT OR IGNORE INTO messages
                    (message_id, ts, session_id, parent_session_id, model, input, output, cache_write, cache_read, tool)
                SELECT ?1, ?2, ?3, NULL, ?4, ?5, ?6, ?7, ?8, '\(Tool.chatgpt.rawValue)'
                WHERE NOT EXISTS (SELECT 1 FROM rolled_message_ids WHERE message_id = ?1)
                  AND ?2 >= coalesce((SELECT value FROM meta WHERE key = 'forgotten_before'), 0)
                """)
            var added = 0
            for event in events {
                guard let usage = event.usage else { continue }
                try insert.run([.text(event.deduplicationKey), .real(event.timestamp.timeIntervalSince1970),
                                .text(event.sessionID), .text(event.model ?? "")] + TokenCounts(codex: usage).sqlValues)
                added += db.changes
            }
            let session = try db.prepare("""
                INSERT INTO chatgpt_sessions (session_id, creator_user_id, parent_session_id) VALUES (?1, ?2, ?3)
                ON CONFLICT (session_id) DO UPDATE SET
                    creator_user_id = excluded.creator_user_id, parent_session_id = excluded.parent_session_id
                """)
            for meta in scan.sessions {
                try session.run([.text(meta.id), .text(meta.creatorUserID), .text(meta.parentThreadID)])
            }
            let save = try db.prepare("INSERT OR REPLACE INTO chatgpt_files (path, cursor) VALUES (?1, ?2)")
            let encoder = JSONEncoder()
            for (path, cursor) in changed {
                try save.run([.text(path), .text(String(decoding: try encoder.encode(cursor), as: UTF8.self))])
            }
            let forget = try db.prepare("DELETE FROM chatgpt_files WHERE path = ?1")
            for path in gone { try forget.run([.text(path)]) }
            return added
        }
        chatgptCursorCache = scan.cursors
        if added > 0 { revision += 1 }
        return added
    }
}

extension TokenCounts {
    /// ChatGPT 的四类映射（spec "会话记录、账本与归属"）：输入 = input_tokens − cached_input_tokens，
    /// 缓存读取 = cached_input_tokens，缓存写入 = cache_write_input_tokens，输出 = output_tokens（已含推理）
    init(codex usage: CodexTokenUsage) {
        self.init(input: max(0, usage.input - usage.cachedInput), output: usage.output,
                  cacheWrite: usage.cacheWriteInput, cacheRead: usage.cachedInput)
    }
}

// MARK: - 会话（ChatGPTSessionAttribution 用）

/// 账本里记着的一个 ChatGPT 会话
struct ChatGPTSessionRecord {
    /// session_meta 的 creator_user_id：①② 都没有证据时按它归属（见 ChatGPTSessionAttribution ③）
    var creatorUserID: String?
    /// 子代理会话的父线程
    var parentSessionID: String?
    /// 观察到的写入档案（写它的进程的 CODEX_HOME）与观察时刻；没观察到过时为 nil。
    /// profile 为 nil 表示写入进程的 CODEX_HOME 是 cc-pilot 管理范围以外的目录
    var observed: (profile: String?, at: Date)?
}

extension TokenLedger {
    /// 记着的会话；没读到过它的 session_meta、也没观察到过写入者时为 nil
    func chatgptSession(_ sessionID: String) throws -> ChatGPTSessionRecord? {
        let statement = try db.prepare("""
            SELECT creator_user_id, parent_session_id, profile, observed_at FROM chatgpt_sessions WHERE session_id = ?1
            """)
        try statement.bind([.text(sessionID)])
        guard try statement.step() else { return nil }
        var record = ChatGPTSessionRecord(creatorUserID: statement.text(0), parentSessionID: statement.text(1))
        // observed_at 只由 recordChatGPTWriter 写，与 profile 一起；profile 为空、observed_at 不为空是外部目录
        if statement.text(3) != nil {
            record.observed = (statement.text(2), Date(timeIntervalSince1970: statement.double(3)))
        }
        return record
    }

    /// 以前（还不按创建者归属时）记为未归属的明细是否已经按创建者重新看过一次（ChatGPTSessionAttribution）
    func chatgptCreatorBackfillDone() throws -> Bool {
        let statement = try db.prepare("SELECT 1 FROM meta WHERE key = 'chatgpt_creator_backfill'")
        return try statement.step()
    }

    func markChatGPTCreatorBackfillDone(at time: Date) throws {
        try db.run("INSERT OR IGNORE INTO meta (key, value) VALUES ('chatgpt_creator_backfill', ?1)",
                   [.real(time.timeIntervalSince1970)])
    }

    /// 记下观察到的写入档案（覆盖之前的）；profile 为 nil 表示写入进程的 CODEX_HOME 是外部目录。
    /// 不算账本变化（revision 不变）
    func recordChatGPTWriter(sessionID: String, profile: String?, at time: Date) throws {
        try db.run("""
            INSERT INTO chatgpt_sessions (session_id, profile, observed_at) VALUES (?1, ?2, ?3)
            ON CONFLICT (session_id) DO UPDATE SET profile = excluded.profile, observed_at = excluded.observed_at
            """, [.text(sessionID), .text(profile), .real(time.timeIntervalSince1970)])
    }
}
