// 把账本里待归属的明细归属到账号（token-usage ticket 02）：会话 ID → 档案 → 档案此刻登录的账号。
//
// 会话 → 档案：每个档案自己的 history.jsonl（默认档案 ~/.claude/history.jsonl，其他档案
// <configDir>/history.jsonl）里，用户每提交一次输入记一行，带 sessionId。projects/ 是共享资源，
// 会话记录本身不知道属于哪个档案，只能靠它。子代理的明细用父会话的 ID 查（账本已处理）。
// 同一个会话出现在几个档案的 history.jsonl 里（在另一个档案里 resume）时，取最新一行所在的档案：
// 归属在消息读入后很快进行，最新一行就是此刻在跑这个会话的档案。时间相同时按档案列表顺序取前一个。
//
// 档案 → 账号：读入时（即归属时）该档案登录的账号，规则同 Profile.usageAccount，记进账本的是
// UsageAccount.id（"account:<uuid>"，或没有 uuid 时 "profile:<名字>"）。账本只改待归属的明细，
// 档案之后换登录不影响旧记录。首次回填时只能按档案当前的账号算（spec 决策 3）。
//
// 找不到归属：history.jsonl 的条目可能比消息晚写出来，.claude.json 也可能正被 Claude Code 重写而暂时
// 读不出账号，所以先不下结论；会话里最新一条待归属明细过了 `grace` 仍找不到时才记为未归属
// （例如 claude -p 这类不写 history.jsonl 的会话）。
//
// history.jsonl 增量读取：记住每个文件读到的位置和 inode，只读新追加的完整行；文件变短或换了
// inode 时从头读。索引只在内存里，App 启动后第一次归属时读全量。
// 会话进行中每隔一两秒就同步一次，所以只读找到了会话的那几个档案的 .claude.json（它可能有几 MB），
// 没有待归属的明细时什么也不读。
// 只在一个线程（或串行队列）上使用；TokenUsageRecorder 在它的队列上调用 `attribute`。

import Foundation

final class SessionAttribution {
    /// 找不到归属时等多久再记为未归属
    static let defaultGrace: TimeInterval = 60 * 60

    private let environment: CoreEnvironment
    private let grace: TimeInterval
    private let now: () -> Date
    /// history.jsonl 路径 → 读取状态
    private var histories: [String: HistoryIndex] = [:]

    init(environment: CoreEnvironment, grace: TimeInterval = SessionAttribution.defaultGrace,
         now: @escaping () -> Date = Date.init) {
        self.environment = environment
        self.grace = grace
        self.now = now
    }

    /// 给账本里所有待归属的会话定归属（TokenUsageRecorder 的归属钩子）
    func attribute(_ ledger: TokenLedger) throws {
        let pending = try ledger.pendingSessions()
        guard !pending.isEmpty else { return }
        let paths = ProfilePaths(environment: environment)
        let store = ProfileStore(environment: environment)
        let names = [ProfileName.defaultName] + store.profileNames()
        let historyPaths = names.map { paths.runtimeDir(forProfileNamed: $0) + "/history.jsonl" }
        // 已经不是档案的 history.jsonl 不再参与
        histories = histories.filter { historyPaths.contains($0.key) }
        let indexes = historyPaths.map { path -> HistoryIndex in
            let index = histories[path] ?? HistoryIndex()
            index.update(path: path)
            histories[path] = index
            return index
        }

        var accounts: [String: UsageAccount?] = [:]
        func account(of name: String) -> UsageAccount? {
            if let cached = accounts[name] { return cached }
            let account = store.profile(named: name).usageAccount
            accounts[name] = account
            return account
        }
        let deadline = now().addingTimeInterval(-grace)
        for session in pending {
            var best: (name: String, timestamp: Double)?
            for (name, index) in zip(names, indexes) {
                guard let ts = index.sessions[session.sessionID] else { continue }
                if best == nil || ts > best!.timestamp { best = (name, ts) }
            }
            if let name = best?.name, let account = account(of: name) {
                try ledger.attribute(sessionID: session.sessionID, as: .attributed(profile: name, account: account.id))
            } else if session.latest < deadline {
                try ledger.attribute(sessionID: session.sessionID, as: .unattributed)
            }
        }
    }

    /// 一份 history.jsonl 里出现过的会话，及各会话最新一行的时间（毫秒）
    private final class HistoryIndex {
        private(set) var sessions: [String: Double] = [:]
        private var offset = 0
        private var inode = 0

        func update(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else {
                (sessions, offset, inode) = ([:], 0, 0)
                return
            }
            let size = Int(info.st_size)
            if Int(info.st_ino) != inode || size < offset {
                (sessions, offset, inode) = ([:], 0, Int(info.st_ino))
            }
            guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                  let data = try? handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A)
            else { return }
            let complete = data[data.startIndex...lastNewline]
            for line in complete.split(separator: 0x0A) {
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let session = object["sessionId"] as? String, !session.isEmpty
                else { continue }
                let ts = (object["timestamp"] as? NSNumber)?.doubleValue ?? 0
                sessions[session] = max(sessions[session] ?? ts, ts)
            }
            offset += complete.count
        }
    }
}
