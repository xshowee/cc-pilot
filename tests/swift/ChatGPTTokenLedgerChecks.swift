// chatgpt-profiles ticket 09：ChatGPT 会话的 Token 用量记进同一个账本（工具维度），迁移不丢 Claude 的已有数据。
//
// 检查的接口（seam）：
//   TokenLedger(at:)                       打开旧版账本时迁移
//   TokenLedger.ingest(chatgpt:)           读入会话记录读取器（CodexSessionReader）的一次扫描
//   TokenLedger.chatgptCursors()           持久化的读取位置（下次扫描从这里接着读）
//   TokenLedger.messages() / pendingSessions(tool:) / dailyUsage() / cumulativeUsage(account:)
// 会话记录是合成的（CodexRolloutFixtures），写在临时主目录的 .codex/ 下；期望值手算（spec "会话记录、账本与归属"：
// 输入 = input − cached，缓存读取 = cached，缓存写入 = cache_write，输出 = output）。

import Foundation

final class ChatGPTTokenLedgerChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("旧版账本（user_version 4，带 Claude 数据）升级后 Claude 的明细、汇总、起算点、读取位置都不变",
                  migratesKeepingClaudeData),
            Check("每个 token_count 按 last_token_usage 记一条（不用 total），四类映射；只有 rate_limits 的不记",
                  mapsLastTokenUsage),
            Check("增量读：读取位置与明细一起存进账本，重新打开账本后只读新追加的完整行", readsIncrementallyAcrossReopen),
            Check(".zst 压缩的会话记录也记；没变时不重读", ingestsZst),
            Check("resume、fork 把旧事件带进另一份文件：只记一次；之后的新事件照常记", dedupsResumeAndFork),
            Check("ChatGPT 账号的保留期汇总、窗口、累计、清空规则同 Claude，互不影响", sameRulesAsClaude),
        ]
    }

    static let sessionA = "019a4f00-0000-7000-8000-00000000000a"
    static let sessionB = "019a4f00-0000-7000-8000-00000000000b"
    static let sessionC = "019a4f00-0000-7000-8000-00000000000c"
    static let t0 = "2026-11-04T10:00:00.000Z"
    static let t1 = "2026-11-04T10:01:00.000Z"
    static let t2 = "2026-11-04T10:02:00.000Z"
    static let t3 = "2026-11-04T10:03:00.000Z"

    /// 读一次会话目录（从账本记着的位置接着读）并记进账本；返回新记入的条数
    @discardableResult
    static func ingest(_ home: TempHome, _ ledger: TokenLedger) throws -> Int {
        let scan = CodexSessionReader(environment: home.environment).scan(try ledger.chatgptCursors())
        return try ledger.ingest(chatgpt: scan)
    }

    static func openLedger(_ home: TempHome) throws -> TokenLedger {
        try TokenLedger(at: TokenLedger.defaultURL(environment: home.environment))
    }

    // MARK: - 读入

    static func mapsLastTokenUsage() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(CodexRollout.path(sessionA), CodexRollout.file([
            CodexRollout.meta(id: sessionA, at: t0),
            CodexRollout.turnContext(model: "gpt-5.1-codex-max", at: t0),
            // 会话刚开始：info 为 null，只带 rate_limits
            CodexRollout.tokenCount(at: t0, last: nil, primary: .init(used: 5, minutes: 300, resetsAt: 1_793_800_000)),
            CodexRollout.tokenCount(at: t1, last: .init(input: 1000, cached: 800, output: 50, reasoning: 20, cacheWrite: 5),
                                    total: .init(input: 5000, cached: 4000, output: 300, reasoning: 100, cacheWrite: 9)),
            CodexRollout.tokenCount(at: t2, last: .init(input: 30, output: 4), total: .init(input: 5030, cached: 4000, output: 304)),
        ]))
        let ledger = try openLedger(home)
        try expectEqual(try ingest(home, ledger), 2)
        let messages = try ledger.messages()
        try expectEqual(messages.map(\.tokens), [
            // 输入 = 1000 − 800，缓存读取 = 800，缓存写入 = 5，输出 = 50（已含推理 20）
            TokenCounts(input: 200, output: 50, cacheWrite: 5, cacheRead: 800),
            // 旧版没有 cache_write_input_tokens：缓存写入 0
            TokenCounts(input: 30, output: 4, cacheWrite: 0, cacheRead: 0),
        ])
        try expectEqual(messages.map(\.tool), [.chatgpt, .chatgpt])
        try expectEqual(messages.map(\.sessionID), [sessionA, sessionA])
        try expectEqual(messages.map(\.model), ["gpt-5.1-codex-max", "gpt-5.1-codex-max"])
        try expectEqual(messages.map(\.timestamp), [Date(timeIntervalSince1970: 1_793_786_460),
                                                    Date(timeIntervalSince1970: 1_793_786_520)])
        try expectEqual(messages.map(\.attribution), [.pending, .pending])
        try expect(messages.allSatisfy { $0.messageID?.hasPrefix("codex:") == true }, "message_id 是去重键")
        try expectEqual(try ledger.pendingSessions(tool: .chatgpt).map(\.sessionID), [sessionA])
        try expectEqual(try ledger.pendingSessions(tool: .claudeCode).map(\.sessionID), [])
    }

    // MARK: - 迁移

    /// 旧版（v4）账本的结构：照 v1 建表 + v2/v3 的改动手写，不经 TokenLedger
    static let version4Schema = """
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY, message_id TEXT UNIQUE, ts REAL NOT NULL, session_id TEXT NOT NULL,
            parent_session_id TEXT, model TEXT NOT NULL,
            input INTEGER NOT NULL, output INTEGER NOT NULL, cache_write INTEGER NOT NULL, cache_read INTEGER NOT NULL,
            attribution INTEGER NOT NULL DEFAULT 0, profile TEXT, account TEXT);
        CREATE INDEX messages_ts ON messages(ts);
        CREATE INDEX messages_session ON messages(coalesce(parent_session_id, session_id));
        CREATE TABLE daily (
            day TEXT NOT NULL, day_start REAL NOT NULL, account TEXT NOT NULL, model TEXT NOT NULL,
            input INTEGER NOT NULL, output INTEGER NOT NULL, cache_write INTEGER NOT NULL, cache_read INTEGER NOT NULL,
            PRIMARY KEY (day, account, model)) WITHOUT ROWID;
        CREATE TABLE rolled_message_ids (message_id TEXT PRIMARY KEY, ts REAL NOT NULL DEFAULT 0) WITHOUT ROWID;
        CREATE TABLE files (path TEXT PRIMARY KEY, offset INTEGER NOT NULL, inode INTEGER NOT NULL) WITHOUT ROWID;
        CREATE TABLE meta (key TEXT PRIMARY KEY, value REAL NOT NULL) WITHOUT ROWID;
        CREATE TABLE origins (account TEXT PRIMARY KEY, ts REAL NOT NULL) WITHOUT ROWID;
        PRAGMA user_version = 4;
        """

    static func migratesKeepingClaudeData() throws {
        let home = try TempHome()
        defer { home.remove() }
        // 一份已经读完的 Claude 会话记录：位置在文件末尾
        let transcript = ".claude/projects/p/s-a.jsonl"
        try home.write(transcript, TranscriptFixture.file([
            TranscriptFixture.assistant(id: "msg_a", session: "s-a", at: "2026-10-20T10:00:00.000Z", output: 7),
        ]))
        let transcriptPath = home.url.appendingPathComponent(transcript).path
        let attributes = try FileManager.default.attributesOfItem(atPath: transcriptPath)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.intValue ?? 0

        let url = TokenLedger.defaultURL(environment: home.environment)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let db = try SQLiteDatabase(path: url.path)
            try db.execute(version4Schema)
            try db.execute("""
                INSERT INTO messages (message_id, ts, session_id, parent_session_id, model,
                                      input, output, cache_write, cache_read, attribution, profile, account) VALUES
                    ('msg_a', 1792490400, 's-a', NULL, 'claude-opus-5-5', 1, 7, 3, 4, 1, 'work', 'account:uuid-1'),
                    ('msg_p', 1792490500, 's-p', NULL, 'claude-opus-5-5', 2, 8, 0, 0, 0, NULL, NULL),
                    ('msg_s', 1792490600, 's-sub', 's-p', 'claude-sonnet-4-5', 5, 1, 0, 0, 0, NULL, NULL),
                    ('msg_u', 1792490700, 's-u', NULL, 'claude-opus-5-5', 9, 9, 9, 9, 2, NULL, NULL);
                INSERT INTO daily VALUES
                    ('2026-09-01', 1788192000, 'account:uuid-1', 'claude-opus-5-5', 100, 200, 300, 400),
                    ('2026-09-01', 1788192000, '', 'claude-opus-5-5', 1, 2, 3, 4);
                INSERT INTO rolled_message_ids VALUES ('msg_old', 1788192000);
                INSERT INTO meta VALUES ('forgotten_before', 1780000000), ('origin_all', 1780000001);
                INSERT INTO origins VALUES ('account:uuid-1', 1785000000);
                """)
            try db.run("INSERT INTO files VALUES (?1, ?2, ?3)", [.text(transcriptPath), .int(size), .int(inode)])
        }

        let ledger = try TokenLedger(at: url)
        func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        try expectEqual(try ledger.messages(), [
            LedgerMessage(messageID: "msg_a", timestamp: at(1_792_490_400), sessionID: "s-a", parentSessionID: nil,
                          model: "claude-opus-5-5", tokens: TokenCounts(input: 1, output: 7, cacheWrite: 3, cacheRead: 4),
                          attribution: .attributed(profile: "work", account: "account:uuid-1")),
            LedgerMessage(messageID: "msg_p", timestamp: at(1_792_490_500), sessionID: "s-p", parentSessionID: nil,
                          model: "claude-opus-5-5", tokens: TokenCounts(input: 2, output: 8, cacheWrite: 0, cacheRead: 0),
                          attribution: .pending),
            LedgerMessage(messageID: "msg_s", timestamp: at(1_792_490_600), sessionID: "s-sub", parentSessionID: "s-p",
                          model: "claude-sonnet-4-5", tokens: TokenCounts(input: 5, output: 1, cacheWrite: 0, cacheRead: 0),
                          attribution: .pending),
            LedgerMessage(messageID: "msg_u", timestamp: at(1_792_490_700), sessionID: "s-u", parentSessionID: nil,
                          model: "claude-opus-5-5", tokens: TokenCounts(input: 9, output: 9, cacheWrite: 9, cacheRead: 9),
                          attribution: .unattributed),
        ])
        try expect(try ledger.messages().allSatisfy { $0.tool == .claudeCode }, "旧明细都属于 Claude Code")
        try expectEqual(try ledger.dailyUsage(), [
            LedgerDailyUsage(day: "2026-09-01", dayStart: at(1_788_192_000), account: "account:uuid-1",
                             model: "claude-opus-5-5",
                             tokens: TokenCounts(input: 100, output: 200, cacheWrite: 300, cacheRead: 400)),
            LedgerDailyUsage(day: "2026-09-01", dayStart: at(1_788_192_000), account: nil, model: "claude-opus-5-5",
                             tokens: TokenCounts(input: 1, output: 2, cacheWrite: 3, cacheRead: 4)),
        ])
        let pending = try ledger.pendingSessions(tool: .claudeCode)
        try expectEqual(pending.map(\.sessionID), ["s-p"], "子代理随父会话")
        try expectEqual(pending.first?.latest, at(1_792_490_600))
        // 起算点：账号自己的和 origin_all 取较晚者；累计 = 起算点之后的明细 + 汇总（那天 0 点不早于起算点）
        let cumulative = try ledger.cumulativeUsage(account: "account:uuid-1")
        try expectEqual(cumulative.origin, at(1_785_000_000))
        try expectEqual(cumulative.usage.tokens, TokenCounts(input: 101, output: 207, cacheWrite: 303, cacheRead: 404))
        try expectEqual(try ledger.rolledMessageIDCount(), 1)
        // 读取位置还在：不重读那份会话记录
        try expectEqual(try ledger.ingest(projectsRoot: home.url.appendingPathComponent(".claude/projects")), 0)
        // 再打开一次不再迁移，数据照旧
        let reopened = try TokenLedger(at: url)
        try expectEqual(try reopened.messages().count, 4)
    }

    static func readsIncrementallyAcrossReopen() throws {
        let home = try TempHome()
        defer { home.remove() }
        let path = CodexRollout.path(sessionA)
        try home.write(path, CodexRollout.file([
            CodexRollout.meta(id: sessionA, at: t0),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: t0),
            CodexRollout.tokenCount(at: t1, last: .init(input: 10, output: 1)),
        ]))
        do {
            let ledger = try openLedger(home)
            try expectEqual(try ingest(home, ledger), 1)
            try expectEqual(try ingest(home, ledger), 0, "没有新内容")
        }
        // App 重启：新打开的账本从记着的位置接着读；写到一半的行留到下次
        let line = CodexRollout.tokenCount(at: t2, last: .init(input: 20, output: 2),
                                           total: .init(input: 30, output: 3))
        let half = line.index(line.startIndex, offsetBy: line.count / 2)
        try append(home, path, String(line[..<half]))
        let ledger = try openLedger(home)
        try expectEqual(try ingest(home, ledger), 0, "半行不读")
        try append(home, path, String(line[half...]) + "\n")
        try expectEqual(try ingest(home, ledger), 1)
        let messages = try ledger.messages()
        try expectEqual(messages.map(\.tokens.input), [10, 20])
        try expectEqual(messages.map(\.model), ["gpt-5.3-codex", "gpt-5.3-codex"], "接着读时记得之前的 turn_context")
        try expectEqual(try openLedger(home).chatgptCursors(), try ledger.chatgptCursors())
    }

    static func append(_ home: TempHome, _ path: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: home.url.appendingPathComponent(path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    static func ingestsZst() throws {
        let home = try TempHome()
        defer { home.remove() }
        let content = Data(CodexRollout.file([
            CodexRollout.meta(id: sessionB, at: t0, originator: "Codex Desktop"),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: t0),
            CodexRollout.tokenCount(at: t1, last: .init(input: 100, cached: 60, output: 10)),
            CodexRollout.tokenCount(at: t2, last: .init(input: 50, output: 5), total: .init(input: 150, cached: 60, output: 15)),
        ]).utf8)
        let file = home.url.appendingPathComponent(CodexRollout.path(sessionB, root: "archived_sessions", compressed: true))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try RawZstdFrame.wrap(content).write(to: file)
        let ledger = try openLedger(home)
        try expectEqual(try ingest(home, ledger), 2)
        try expectEqual(try ledger.messages().map(\.tokens), [
            TokenCounts(input: 40, output: 10, cacheWrite: 0, cacheRead: 60),
            TokenCounts(input: 50, output: 5, cacheWrite: 0, cacheRead: 0),
        ])
        try expectEqual(try ledger.messages().map(\.sessionID), [sessionB, sessionB])
        let reopened = try openLedger(home)
        try expect(try reopened.chatgptCursors()[file.path] != nil, "重新打开账本后记得 .zst 的位置")
        let rescan = CodexSessionReader(environment: home.environment).scan(try reopened.chatgptCursors())
        try expect(rescan.events.isEmpty, "没变的 .zst 不重读")
    }

    static func dedupsResumeAndFork() throws {
        let home = try TempHome()
        defer { home.remove() }
        let first = CodexRollout.tokenCount(at: t1, last: .init(input: 10, output: 1))
        let second = CodexRollout.tokenCount(at: t2, last: .init(input: 20, output: 2), total: .init(input: 30, output: 3))
        try home.write(CodexRollout.path(sessionA), CodexRollout.file([
            CodexRollout.meta(id: sessionA, at: t0),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: t0),
            first, second,
        ]))
        let ledger = try openLedger(home)
        try expectEqual(try ingest(home, ledger), 2)
        // 会话被 fork：新文件先写自己的 session_meta，再重放父会话（时间戳是重放时的），之后是自己的新事件
        let replayed = "2026-11-04T11:00:00.000Z"
        try home.write(CodexRollout.path(sessionB, day: "2026/11/05"), CodexRollout.file([
            CodexRollout.meta(id: sessionB, at: replayed, forkedFrom: sessionA),
            CodexRollout.meta(id: sessionA, at: replayed),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: replayed),
            CodexRollout.tokenCount(at: replayed, last: .init(input: 10, output: 1)),
            CodexRollout.tokenCount(at: replayed, last: .init(input: 20, output: 2), total: .init(input: 30, output: 3)),
            CodexRollout.tokenCount(at: t3, last: .init(input: 40, output: 4), total: .init(input: 70, output: 7)),
        ]))
        // 同一个会话的记录被移进 archived_sessions（换了路径）：从头读，但不重复计入
        try FileManager.default.createDirectory(
            at: home.url.appendingPathComponent(".codex/archived_sessions/2026/11/04"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: home.url.appendingPathComponent(CodexRollout.path(sessionA)),
                                         to: home.url.appendingPathComponent(CodexRollout.path(sessionA, root: "archived_sessions")))
        try expectEqual(try ingest(home, ledger), 1, "只有 fork 之后的新事件")
        let messages = try ledger.messages()
        try expectEqual(messages.map(\.tokens.input), [10, 20, 40])
        try expectEqual(messages.map(\.sessionID), [sessionA, sessionA, sessionB])
    }

    // MARK: - 保留期、窗口、累计、清空

    static func sameRulesAsClaude() throws {
        let home = try TempHome()
        defer { home.remove() }
        let chatgpt = "chatgpt:user-w:ws-1", claude = "account:u-1"
        // 一次很早（会超过保留期）、一次在当前 5 小时窗口里
        try home.write(CodexRollout.path(sessionA), CodexRollout.file([
            CodexRollout.meta(id: sessionA, at: "2026-09-01T02:00:00.000Z"),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: "2026-09-01T02:00:00.000Z"),
            CodexRollout.tokenCount(at: "2026-09-01T02:00:00.000Z", last: .init(input: 100, output: 10)),
            CodexRollout.tokenCount(at: "2026-11-04T10:00:00.000Z", last: .init(input: 20, cached: 5, output: 2),
                                    total: .init(input: 120, cached: 5, output: 12)),
        ]))
        try home.write(".claude/projects/p/s-1.jsonl", TranscriptFixture.file([
            TranscriptFixture.assistant(id: "m1", session: "s-1", at: "2026-11-04T10:00:00.000Z", output: 7),
        ]))
        let ledger = try openLedger(home)
        try ingest(home, ledger)
        try ledger.ingest(projectsRoot: home.url.appendingPathComponent(".claude/projects"))
        try ledger.attribute(sessionID: sessionA, as: .attributed(profile: "work", account: chatgpt), tool: .chatgpt)
        try ledger.attribute(sessionID: "s-1", as: .attributed(profile: "work", account: claude))

        let now = TranscriptLine.parseTimestamp("2026-11-04T12:00:00Z")!
        try ledger.rollUp(now: now, retentionDays: 35, calendar: TokenLedgerRollupChecks.calendar)
        try expectEqual(try ledger.dailyUsage().map(\.account), [chatgpt], "保留期之前的 ChatGPT 明细按账号汇总")
        try expectEqual(try ledger.dailyUsage().map(\.tokens), [TokenCounts(input: 100, output: 10, cacheWrite: 0, cacheRead: 0)])

        let resets = KnownResets(fiveHour: TranscriptLine.parseTimestamp("2026-11-04T14:00:00Z"), sevenDay: nil)
        let usage = try ledger.accountUsage(chatgpt, resets: resets, now: now, calendar: TokenLedgerRollupChecks.calendar)
        try expectEqual(usage.fiveHour.usage.tokens, TokenCounts(input: 15, output: 2, cacheWrite: 0, cacheRead: 5))
        try expectEqual(usage.fiveHour.usage.byModel.map(\.model), ["GPT-5.3-Codex"])
        try expectEqual(usage.cumulative.usage.tokens, TokenCounts(input: 115, output: 12, cacheWrite: 0, cacheRead: 5))

        // 清空 ChatGPT 账号不影响 Claude 账号；"清空全部账号"两边都清
        try ledger.clearCumulative(account: chatgpt, at: now)
        try expectEqual(try ledger.cumulativeUsage(account: chatgpt).usage.tokens, .zero)
        try expectEqual(try ledger.cumulativeUsage(account: claude).usage.tokens.output, 7)
        try ledger.clearCumulative(account: chatgpt, at: now.addingTimeInterval(-3 * 3600))
        try expectEqual(try ledger.cumulativeUsage(account: chatgpt).usage.tokens.output, 2)
        try ledger.clearAllCumulative(at: now)
        try expectEqual(try ledger.cumulativeUsage(account: chatgpt).usage.tokens, .zero)
        try expectEqual(try ledger.cumulativeUsage(account: claude).usage.tokens, .zero)
    }
}
