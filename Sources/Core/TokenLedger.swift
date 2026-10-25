// cc-pilot 自己的 Token 用量账本（spec 决策 11）：~/Library/Application Support/cc-pilot/token-usage.sqlite。
// 只读 Claude Code 的会话记录，从不改动它们；会话记录被删除不影响账本。
//
// 数据（SQLite，PRAGMA user_version = 4）：
//   messages  逐条明细：每条 assistant 消息一行，message.id 唯一（没有 id 的行各占一行）。
//             attribution 是归属状态（见 LedgerAttribution），由 ticket 02 填写；读入时一律是"待归属"。
//   daily     超过保留期的明细合并成的"每账号、每模型、每天"汇总；account 为空串表示未归属。
//   rolled_message_ids  已合并进汇总的 message.id 及消息时间。resume/fork 出来的会话记录会原样带上旧消息，
//             这些旧消息的明细已经删掉了，靠它防止再记一次。只记两个保留期：更早的忘掉，
//             忘掉的分界记在 meta 的 forgotten_before，读入时早于它的行一律跳过（它们所在的日子早已汇总，
//             能出现只可能是 resume 链一路带下来的旧消息），这样表不会无限增长，也不会重记。
//   meta      键值：forgotten_before（见上）；origin_all（"清空全部账号"的时刻，见下）。
//   origins   每个账号的起算点（ticket 03）：清空这个账号时的时刻；account 为空串表示未归属。
//   files     每份会话记录读到的位置（字节偏移）和 inode。与明细在同一个事务里写入，
//             中途退出也不会重复计入或漏记。
//
// 读取规则：
//   - 会话记录是 projects/<项目>/<会话>.jsonl 和 projects/<项目>/<父会话>/subagents/*.jsonl。
//   - 只读新追加的部分，到最后一个换行为止；写到一半的最后一行留到下次。
//   - 文件变短或换了 inode（被重写）时从头读；有 message.id 的行靠去重不会重复。
//
// 起算点（累计 Token 用量从哪一刻算起，ticket 03）：
//   - 账号的起算点 = origins 里它的时刻和 origin_all 中较晚的那个；都没有时是它在账本里最早一条记录的时间。
//   - "清空全部账号"只记 origin_all，不逐个写账号：清空之前的消息之后才归属到一个从没出现过的账号，也不会算进累计。
//   - 起算点按消息时间比较；按天汇总只有日期，那天的 0 点不早于起算点才计入（起算点落在已汇总的那天中间时，
//     那天整天不计）。
//
// 只在一个线程（或串行队列）上使用同一个 TokenLedger。

import Foundation

/// 明细的归属状态（ticket 02）
enum LedgerAttribution: Equatable, Sendable {
    /// 还没确定（对应的 history.jsonl 条目可能还没写出来）；不汇总
    case pending
    /// 归属到某个档案当时登录的账号
    case attributed(profile: String, account: String)
    /// 确定找不到归属：记账但不计入任何账号
    case unattributed
}

/// 账本里的一条明细
struct LedgerMessage: Equatable, Sendable {
    let messageID: String?
    let timestamp: Date
    /// 行里的 sessionId
    let sessionID: String
    /// 子代理会话记录所属的父会话（取自路径 projects/<项目>/<父会话>/subagents/）；主会话记录为 nil
    let parentSessionID: String?
    /// 原始模型 ID
    let model: String
    let tokens: TokenCounts
    let attribution: LedgerAttribution

    /// 归属时用来查 history.jsonl 的会话 ID：子代理用父会话
    var attributionSessionID: String { parentSessionID ?? sessionID }
}

/// 超过保留期的明细合并成的一行汇总：某账号、某模型、某个本地日期
struct LedgerDailyUsage: Equatable, Sendable {
    /// 本地日期，yyyy-MM-dd
    let day: String
    /// 这一天本地 0 点（合并时的时区）
    let dayStart: Date
    /// 归属的账号；nil 表示未归属
    let account: String?
    /// 原始模型 ID
    let model: String
    let tokens: TokenCounts
}

final class TokenLedger {
    private let db: SQLiteDatabase

    /// 明细、归属或汇总每变化一次就加一（只在内存里，从 0 开始）；读取位置、起算点的变化不算。
    /// TokenUsageRecorder 据此判断一次同步有没有带来变化。
    private(set) var revision = 0

    /// 真实位置：<HOME>/Library/Application Support/cc-pilot/token-usage.sqlite。
    /// 从 environment.home 算出（不用 FileManager 的 applicationSupportDirectory，它不看 HOME，检查时会写到真实目录）。
    static func defaultURL(environment: CoreEnvironment) -> URL {
        URL(fileURLWithPath: ProfilePaths(environment: environment).homePath
            + "/Library/Application Support/cc-pilot/token-usage.sqlite")
    }

    /// 打开账本（不存在时创建，连同所在目录）
    init(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        db = try SQLiteDatabase(path: url.path)
        try db.execute("PRAGMA journal_mode = WAL")
        try migrate()
    }

    private func migrate() throws {
        let version = try db.prepare("PRAGMA user_version")
        let current = try version.step() ? version.int(0) : 0
        if current < 1 { try createVersion1() }
        if current < 2 {
            // 旧的 message.id 不知道消息时间，按升级时刻算：至少再记两个保留期
            try db.transaction {
                try db.execute("""
                    ALTER TABLE rolled_message_ids ADD COLUMN ts REAL NOT NULL DEFAULT 0;
                    CREATE TABLE meta (key TEXT PRIMARY KEY, value REAL NOT NULL) WITHOUT ROWID;
                    """)
                try db.run("UPDATE rolled_message_ids SET ts = ?1", [.real(Date().timeIntervalSince1970)])
                try db.execute("PRAGMA user_version = 2")
            }
        }
        if current < 3 {
            try db.transaction {
                try db.execute("""
                    CREATE TABLE origins (account TEXT PRIMARY KEY, ts REAL NOT NULL) WITHOUT ROWID;
                    PRAGMA user_version = 3;
                    """)
            }
        }
        if current < 4 {
            // 之前没读 advisor 的用量（usage.iterations）：忘掉读取位置，全部会话记录从头再读一遍。
            // 已记的消息按 message.id 去重不会重复，补进来的只有 advisor 那几条
            try db.transaction {
                try db.execute("""
                    DELETE FROM files;
                    PRAGMA user_version = 4;
                    """)
            }
        }
    }

    private func createVersion1() throws {
        try db.transaction {
            try db.execute("""
                CREATE TABLE messages (
                    id INTEGER PRIMARY KEY,
                    message_id TEXT UNIQUE,
                    ts REAL NOT NULL,
                    session_id TEXT NOT NULL,
                    parent_session_id TEXT,
                    model TEXT NOT NULL,
                    input INTEGER NOT NULL, output INTEGER NOT NULL,
                    cache_write INTEGER NOT NULL, cache_read INTEGER NOT NULL,
                    attribution INTEGER NOT NULL DEFAULT 0,
                    profile TEXT,
                    account TEXT
                );
                CREATE INDEX messages_ts ON messages(ts);
                CREATE INDEX messages_session ON messages(coalesce(parent_session_id, session_id));
                CREATE TABLE daily (
                    day TEXT NOT NULL,
                    day_start REAL NOT NULL,
                    account TEXT NOT NULL,
                    model TEXT NOT NULL,
                    input INTEGER NOT NULL, output INTEGER NOT NULL,
                    cache_write INTEGER NOT NULL, cache_read INTEGER NOT NULL,
                    PRIMARY KEY (day, account, model)
                ) WITHOUT ROWID;
                CREATE TABLE rolled_message_ids (message_id TEXT PRIMARY KEY) WITHOUT ROWID;
                CREATE TABLE files (path TEXT PRIMARY KEY, offset INTEGER NOT NULL, inode INTEGER NOT NULL)
                    WITHOUT ROWID;
                PRAGMA user_version = 1;
                """)
        }
    }

    // MARK: - 读入会话记录

    /// 增量读取 projectsRoot（~/.claude/projects）下的会话记录；返回新记入的消息数。
    /// projects 是只扫描的项目（projectsRoot 下的目录名），nil 扫描全部；首次调用即回填现有的全部会话记录。
    /// projectsRoot 不存在时什么也不做。
    @discardableResult
    func ingest(projectsRoot: URL, projects: Set<String>? = nil) throws -> Int {
        let files = Self.transcriptFiles(in: projectsRoot, projects: projects)
        var added = 0
        let positions = try readPositions()
        let statements = try IngestStatements(db)
        for file in files {
            // 每个文件单独提交：后面的文件出错时，前面已记入的也算变化
            let count = try ingest(file, from: positions[file.path], statements)
            if count > 0 { revision += 1 }
            added += count
        }
        // 已经不存在的文件忘掉读取位置（账本里的明细不动）。只看扫描过的项目：没扫描的项目里的文件
        // 不在 files 里，但还在，忘掉它们的位置会从头重读、重复计入没有 message.id 的行
        let present = Set(files.map(\.path))
        let prefixes = projects.map { $0.map { projectsRoot.path + "/" + $0 + "/" } }
        let gone = positions.keys.filter { path in
            !present.contains(path) && (prefixes?.contains { path.hasPrefix($0) } ?? true)
        }
        if !gone.isEmpty {
            let forget = try db.prepare("DELETE FROM files WHERE path = ?1")
            try db.transaction {
                for path in gone { try forget.run([.text(path)]) }
            }
        }
        return added
    }

    private struct TranscriptFile {
        let path: String
        let parentSessionID: String?
    }

    /// 读入用的语句，每次 ingest 只准备一次
    private struct IngestStatements {
        let insert: SQLiteStatement
        let savePosition: SQLiteStatement

        init(_ db: SQLiteDatabase) throws {
            insert = try db.prepare("""
                INSERT OR IGNORE INTO messages
                    (message_id, ts, session_id, parent_session_id, model, input, output, cache_write, cache_read)
                SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9
                WHERE (?1 IS NULL OR NOT EXISTS (SELECT 1 FROM rolled_message_ids WHERE message_id = ?1))
                  AND ?2 >= coalesce((SELECT value FROM meta WHERE key = 'forgotten_before'), 0)
                """)
            savePosition = try db.prepare("INSERT OR REPLACE INTO files (path, offset, inode) VALUES (?1, ?2, ?3)")
        }
    }

    /// projects/<项目>/*.jsonl 和 projects/<项目>/<会话>/subagents/*.jsonl；projects 不为 nil 时只看这些项目
    private static func transcriptFiles(in root: URL, projects: Set<String>?) -> [TranscriptFile] {
        let fm = FileManager.default
        func entries(_ path: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }
        func isDirectory(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        var files: [TranscriptFile] = []
        for project in entries(root.path) where projects?.contains(project) ?? true {
            let projectPath = root.path + "/" + project
            guard isDirectory(projectPath) else { continue }
            for entry in entries(projectPath) {
                let path = projectPath + "/" + entry
                if entry.hasSuffix(".jsonl") {
                    if !isDirectory(path) { files.append(TranscriptFile(path: path, parentSessionID: nil)) }
                } else if isDirectory(path) {
                    let subagents = path + "/subagents"
                    for sub in entries(subagents) where sub.hasSuffix(".jsonl") && !isDirectory(subagents + "/" + sub) {
                        files.append(TranscriptFile(path: subagents + "/" + sub, parentSessionID: entry))
                    }
                }
            }
        }
        return files
    }

    private func readPositions() throws -> [String: FilePosition] {
        let statement = try db.prepare("SELECT path, offset, inode FROM files")
        var positions: [String: FilePosition] = [:]
        while try statement.step() {
            positions[statement.text(0) ?? ""] = FilePosition(offset: statement.int(1), inode: statement.int(2))
        }
        return positions
    }

    private func ingest(_ file: TranscriptFile, from position: FilePosition?,
                        _ statements: IngestStatements) throws -> Int {
        guard let read = try AppendedLines(path: file.path, after: position),
              read.position.offset > read.start
        else { return 0 }
        return try db.transaction {
            var added = 0
            for line in read.lines {
                for entry in TranscriptLine.parse(line) {
                    try statements.insert.run([
                        .text(entry.messageID), .real(entry.timestamp.timeIntervalSince1970),
                        .text(entry.sessionID), .text(file.parentSessionID), .text(entry.model),
                    ] + entry.tokens.sqlValues)
                    added += db.changes
                }
            }
            try statements.savePosition.run([.text(file.path), .int(read.position.offset),
                                             .int(read.position.inode)])
            return added
        }
    }

    // MARK: - 查询

    /// 全部逐条明细，按时间排列
    func messages() throws -> [LedgerMessage] {
        try messages(where: "1", [])
    }

    private func messages(where condition: String, _ values: [SQLiteValue]) throws -> [LedgerMessage] {
        let statement = try db.prepare("""
            SELECT message_id, ts, session_id, parent_session_id, model,
                   input, output, cache_write, cache_read, attribution, profile, account
            FROM messages WHERE \(condition) ORDER BY ts, id
            """)
        try statement.bind(values)
        var result: [LedgerMessage] = []
        while try statement.step() {
            result.append(LedgerMessage(
                messageID: statement.text(0), timestamp: Date(timeIntervalSince1970: statement.double(1)),
                sessionID: statement.text(2) ?? "", parentSessionID: statement.text(3), model: statement.text(4) ?? "",
                tokens: statement.tokenCounts(from: 5),
                attribution: Self.attribution(state: statement.int(9), profile: statement.text(10),
                                              account: statement.text(11))))
        }
        return result
    }

    /// 全部汇总，按日期排列（同一天里已归属的账号在前、未归属在后）
    func dailyUsage() throws -> [LedgerDailyUsage] {
        let statement = try db.prepare("""
            SELECT day, day_start, account, model, input, output, cache_write, cache_read
            FROM daily ORDER BY day, account = '', account, model
            """)
        var result: [LedgerDailyUsage] = []
        while try statement.step() {
            let account = statement.text(2) ?? ""
            result.append(LedgerDailyUsage(
                day: statement.text(0) ?? "", dayStart: Date(timeIntervalSince1970: statement.double(1)),
                account: account.isEmpty ? nil : account, model: statement.text(3) ?? "",
                tokens: statement.tokenCounts(from: 4)))
        }
        return result
    }

    // MARK: - 归属（ticket 02）

    /// 还有待归属明细的会话，用归属用的会话 ID（子代理取父会话）表示，按字节序排列；
    /// 附带其中最新一条待归属明细的时间
    func pendingSessions() throws -> [(sessionID: String, latest: Date)] {
        let statement = try db.prepare("""
            SELECT coalesce(parent_session_id, session_id), max(ts) FROM messages WHERE attribution = ?1
            GROUP BY 1
            """)
        try statement.bind([.int(Self.pendingState)])
        var sessions: [(sessionID: String, latest: Date)] = []
        while try statement.step() {
            sessions.append((statement.text(0) ?? "", Date(timeIntervalSince1970: statement.double(1))))
        }
        return sessions.sorted { $0.sessionID.utf8.lexicographicallyPrecedes($1.sessionID.utf8) }
    }

    /// 给一个会话（含它的子代理）的待归属明细定下归属。已经归属过的明细不改：档案之后换登录，旧记录仍算原账号。
    func attribute(sessionID: String, as attribution: LedgerAttribution) throws {
        let values: [SQLiteValue]
        switch attribution {
        case .pending: return
        case .attributed(let profile, let account):
            values = [.int(Self.attributedState), .text(profile), .text(account)]
        case .unattributed:
            values = [.int(Self.unattributedState), .null, .null]
        }
        try db.run("""
            UPDATE messages SET attribution = ?1, profile = ?2, account = ?3
            WHERE attribution = ?4 AND coalesce(parent_session_id, session_id) = ?5
            """, values + [.int(Self.pendingState), .text(sessionID)])
        if db.changes > 0 { revision += 1 }
    }

    // MARK: - 汇总

    /// 把保留期之前（本地日期 now − retentionDays 那天的 0 点之前）的明细合并进"每账号、每模型、每天"汇总，
    /// 删掉这些明细。只合并已经确定归属的（未归属的合进 account 为空的汇总）；待归属的留着，归属后下次再合并。
    /// 按整天合并，日期按 calendar（App 里是系统当前的日历和时区）计算。
    /// 同时忘掉两个保留期之前（本地日期 now − 2 × retentionDays 那天的 0 点之前）的已汇总 message.id。
    func rollUp(now: Date, retentionDays: Int, calendar: Calendar) throws {
        guard let back = calendar.date(byAdding: .day, value: -retentionDays, to: now),
              let farBack = calendar.date(byAdding: .day, value: -2 * retentionDays, to: now)
        else { return }
        let cutoff = calendar.startOfDay(for: back)
        let forgetBefore = calendar.startOfDay(for: farBack)
        try db.transaction {
            let select = try db.prepare("""
                SELECT id, message_id, ts, model, input, output, cache_write, cache_read, account
                FROM messages WHERE ts < ?1 AND attribution != ?2
                """)
            try select.bind([.real(cutoff.timeIntervalSince1970), .int(Self.pendingState)])
            struct Key: Hashable { let day: String; let account: String; let model: String }
            var totals: [Key: (dayStart: Date, tokens: TokenCounts)] = [:]
            var rowIDs: [Int] = []
            var messageIDs: [(id: String, ts: Double)] = []
            while try select.step() {
                rowIDs.append(select.int(0))
                if let id = select.text(1) { messageIDs.append((id, select.double(2))) }
                let ts = Date(timeIntervalSince1970: select.double(2))
                let day = calendar.dateComponents([.year, .month, .day], from: ts)
                let key = Key(day: String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0),
                              account: select.text(8) ?? "", model: select.text(3) ?? "")
                totals[key, default: (calendar.startOfDay(for: ts), .zero)].tokens += select.tokenCounts(from: 4)
            }
            let upsert = try db.prepare("""
                INSERT INTO daily (day, day_start, account, model, input, output, cache_write, cache_read)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                ON CONFLICT (day, account, model) DO UPDATE SET
                    input = input + excluded.input, output = output + excluded.output,
                    cache_write = cache_write + excluded.cache_write, cache_read = cache_read + excluded.cache_read
                """)
            for (key, value) in totals {
                try upsert.run([.text(key.day), .real(value.dayStart.timeIntervalSince1970), .text(key.account),
                                .text(key.model)] + value.tokens.sqlValues)
            }
            let remember = try db.prepare("INSERT OR IGNORE INTO rolled_message_ids (message_id, ts) VALUES (?1, ?2)")
            for message in messageIDs { try remember.run([.text(message.id), .real(message.ts)]) }
            let delete = try db.prepare("DELETE FROM messages WHERE id = ?1")
            for id in rowIDs { try delete.run([.int(id)]) }
            // 分界只往后移（保留期变短时也不会把已忘掉的又当成没见过）
            try db.run("""
                INSERT INTO meta (key, value) VALUES ('forgotten_before', ?1)
                ON CONFLICT (key) DO UPDATE SET value = max(value, excluded.value)
                """, [.real(forgetBefore.timeIntervalSince1970)])
            try db.run("""
                DELETE FROM rolled_message_ids
                WHERE ts < (SELECT value FROM meta WHERE key = 'forgotten_before')
                """)
            if !rowIDs.isEmpty { revision += 1 }
        }
    }

    /// 记着的已汇总 message.id 个数
    func rolledMessageIDCount() throws -> Int {
        let statement = try db.prepare("SELECT count(*) FROM rolled_message_ids")
        return try statement.step() ? statement.int(0) : 0
    }

    // MARK: - Token 用量（ticket 03）

    /// 一个账号（UsageAccount.id）的窗口 Token 用量、累计 Token 用量和历史数据
    func accountUsage(_ account: String, resets: KnownResets, now: Date, calendar: Calendar) throws
        -> AccountTokenUsage {
        // 历史数据最多往前 30 天；5 小时窗口过了 resets_at 时要从 resets_at 起找消息
        let since = min(now - Double(TokenUsageStats.historyDays + 1) * 86400, resets.fiveHour ?? now)
        let filter = Self.accountFilter(account)
        // 只查明细：按天汇总的都在保留期（至少 35 天）之前，落不进历史数据的 30 天。查出来按时间排列
        let own = try messages(where: "\(filter.messages) AND ts >= ?2",
                               [.text(filter.key), .real(since.timeIntervalSince1970)])
        return TokenUsageStats.account(own: own, resets: resets, cumulative: try cumulativeUsage(account: account),
                                       now: now, calendar: calendar)
    }

    /// 累计 Token 用量：起算点到现在。account 为 nil 表示未归属（不显示，只用于检查）
    func cumulativeUsage(account: String?) throws -> TokenUsageCumulative {
        let filter = Self.accountFilter(account)
        let stored = try storedOrigin(filter.key)
        let from = SQLiteValue.real(stored?.timeIntervalSince1970 ?? -Double.infinity)
        let statement = try db.prepare("""
            SELECT model, sum(input), sum(output), sum(cache_write), sum(cache_read), min(ts) FROM (
                SELECT model, input, output, cache_write, cache_read, ts FROM messages
                WHERE \(filter.messages) AND ts >= ?2
                UNION ALL
                SELECT model, input, output, cache_write, cache_read, day_start FROM daily
                WHERE account = ?1 AND day_start >= ?2
            ) GROUP BY model
            """)
        try statement.bind([.text(filter.key), from])
        var entries: [(model: String, tokens: TokenCounts)] = []
        var earliest: Double?
        while try statement.step() {
            entries.append((statement.text(0) ?? "", statement.tokenCounts(from: 1)))
            earliest = min(earliest ?? .infinity, statement.double(5))
        }
        return TokenUsageCumulative(origin: stored ?? earliest.map(Date.init(timeIntervalSince1970:)),
                                    usage: TokenUsageBreakdown(entries))
    }

    /// 清空一个账号的累计 Token 用量：把起算点移到 now
    func clearCumulative(account: String, at now: Date) throws {
        try db.run("""
            INSERT INTO origins (account, ts) VALUES (?1, ?2)
            ON CONFLICT (account) DO UPDATE SET ts = excluded.ts
            """, [.text(account), .real(now.timeIntervalSince1970)])
    }

    /// 清空全部账号（连同未归属）的累计 Token 用量
    func clearAllCumulative(at now: Date) throws {
        try db.run("""
            INSERT INTO meta (key, value) VALUES ('origin_all', ?1)
            ON CONFLICT (key) DO UPDATE SET value = excluded.value
            """, [.real(now.timeIntervalSince1970)])
    }

    /// 记下的起算点（账号自己的和全部账号的取较晚者）；从没清空过时为 nil
    private func storedOrigin(_ key: String) throws -> Date? {
        let statement = try db.prepare("""
            SELECT max(ts) FROM (
                SELECT ts FROM origins WHERE account = ?1
                UNION ALL SELECT value FROM meta WHERE key = 'origin_all'
            )
            """)
        try statement.bind([.text(key)])
        guard try statement.step(), statement.text(0) != nil else { return nil }
        return Date(timeIntervalSince1970: statement.double(0))
    }

    /// 账号在各表里的写法：messages 的条件（?1 是账号）、daily 和 origins 的键（未归属是空串）
    private static func accountFilter(_ account: String?) -> (messages: String, key: String) {
        guard let account else { return ("attribution = \(unattributedState) AND ?1 = ''", "") }
        return ("attribution = \(attributedState) AND account = ?1", account)
    }

    // MARK: - 归属状态的存储形式

    private static let pendingState = 0, attributedState = 1, unattributedState = 2

    private static func attribution(state: Int, profile: String?, account: String?) -> LedgerAttribution {
        switch state {
        case attributedState: return .attributed(profile: profile ?? "", account: account ?? "")
        case unattributedState: return .unattributed
        default: return .pending
        }
    }
}

private extension TokenCounts {
    /// 按 input、output、cache_write、cache_read 的顺序绑定
    var sqlValues: [SQLiteValue] { [.int(input), .int(output), .int(cacheWrite), .int(cacheRead)] }
}
