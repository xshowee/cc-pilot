// cc-pilot 自己的 Token 用量账本（spec 决策 11）：~/Library/Application Support/cc-pilot/token-usage.sqlite。
// 只读 Claude Code 的会话记录，从不改动它们；会话记录被删除不影响账本。
//
// 数据（SQLite，PRAGMA user_version = 1）：
//   messages  逐条明细：每条 assistant 消息一行，message.id 唯一（没有 id 的行各占一行）。
//             attribution 是归属状态（见 LedgerAttribution），由 ticket 02 填写；读入时一律是"待归属"。
//   daily     超过保留期的明细合并成的"每账号、每模型、每天"汇总；account 为空串表示未归属。
//   rolled_message_ids  已合并进汇总的 message.id。resume/fork 出来的会话记录会原样带上旧消息，
//             这些旧消息的明细已经删掉了，靠它防止再记一次。
//   files     每份会话记录读到的位置（字节偏移）和 inode。与明细在同一个事务里写入，
//             中途退出也不会重复计入或漏记。
//
// 读取规则：
//   - 会话记录是 projects/<项目>/<会话>.jsonl 和 projects/<项目>/<父会话>/subagents/*.jsonl。
//   - 只读新追加的部分，到最后一个换行为止；写到一半的最后一行留到下次。
//   - 文件变短或换了 inode（被重写）时从头读；有 message.id 的行靠去重不会重复。
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

final class TokenLedger {
    private let db: SQLiteDatabase

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
        guard current < 1 else { return }
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

    /// 增量读取 projectsRoot（~/.claude/projects）下的全部会话记录；返回新记入的消息数。
    /// 首次调用即回填现有的全部会话记录。projectsRoot 不存在时什么也不做。
    @discardableResult
    func ingest(projectsRoot: URL) throws -> Int {
        let files = Self.transcriptFiles(in: projectsRoot)
        var added = 0
        let positions = try readPositions()
        for file in files {
            added += try ingest(file, from: positions[file.path])
        }
        // 已经不存在的文件忘掉读取位置（账本里的明细不动）
        let present = Set(files.map(\.path))
        let gone = positions.keys.filter { !present.contains($0) }
        if !gone.isEmpty {
            try db.transaction {
                for path in gone { try db.run("DELETE FROM files WHERE path = ?1", [.text(path)]) }
            }
        }
        return added
    }

    private struct TranscriptFile {
        let path: String
        let parentSessionID: String?
    }

    private struct ReadPosition {
        let offset: Int
        let inode: Int
    }

    /// projects/<项目>/*.jsonl 和 projects/<项目>/<会话>/subagents/*.jsonl
    private static func transcriptFiles(in root: URL) -> [TranscriptFile] {
        let fm = FileManager.default
        func entries(_ path: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }
        func isDirectory(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        var files: [TranscriptFile] = []
        for project in entries(root.path) {
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

    private func readPositions() throws -> [String: ReadPosition] {
        let statement = try db.prepare("SELECT path, offset, inode FROM files")
        var positions: [String: ReadPosition] = [:]
        while try statement.step() {
            positions[statement.text(0) ?? ""] = ReadPosition(offset: statement.int(1), inode: statement.int(2))
        }
        return positions
    }

    private func ingest(_ file: TranscriptFile, from position: ReadPosition?) throws -> Int {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return 0 }
        let size = Int(info.st_size), inode = Int(info.st_ino)
        var offset = position?.offset ?? 0
        if position?.inode != inode || size < offset { offset = 0 }
        guard size > offset, let handle = FileHandle(forReadingAtPath: file.path) else { return 0 }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else { return 0 }
        let complete = data[data.startIndex...lastNewline]

        return try db.transaction {
            let insert = try db.prepare("""
                INSERT OR IGNORE INTO messages
                    (message_id, ts, session_id, parent_session_id, model, input, output, cache_write, cache_read)
                SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9
                WHERE ?1 IS NULL OR NOT EXISTS (SELECT 1 FROM rolled_message_ids WHERE message_id = ?1)
                """)
            var added = 0
            for line in complete.split(separator: 0x0A) {
                guard let entry = TranscriptLine.parse(Data(line)) else { continue }
                try insert.bind([
                    .text(entry.messageID), .real(entry.timestamp.timeIntervalSince1970), .text(entry.sessionID),
                    .text(file.parentSessionID), .text(entry.model),
                    .int(entry.tokens.input), .int(entry.tokens.output),
                    .int(entry.tokens.cacheWrite), .int(entry.tokens.cacheRead),
                ])
                while try insert.step() {}
                added += db.changes
            }
            try db.run("INSERT OR REPLACE INTO files (path, offset, inode) VALUES (?1, ?2, ?3)",
                       [.text(file.path), .int(offset + complete.count), .int(inode)])
            return added
        }
    }

    // MARK: - 查询

    /// 全部逐条明细，按时间排列
    func messages() throws -> [LedgerMessage] {
        let statement = try db.prepare("""
            SELECT message_id, ts, session_id, parent_session_id, model,
                   input, output, cache_write, cache_read, attribution, profile, account
            FROM messages ORDER BY ts, id
            """)
        var result: [LedgerMessage] = []
        while try statement.step() {
            result.append(LedgerMessage(
                messageID: statement.text(0), timestamp: Date(timeIntervalSince1970: statement.double(1)),
                sessionID: statement.text(2) ?? "", parentSessionID: statement.text(3), model: statement.text(4) ?? "",
                tokens: TokenCounts(input: statement.int(5), output: statement.int(6),
                                    cacheWrite: statement.int(7), cacheRead: statement.int(8)),
                attribution: Self.attribution(state: statement.int(9), profile: statement.text(10),
                                              account: statement.text(11))))
        }
        return result
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
