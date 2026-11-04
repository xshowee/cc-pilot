// 把账本里 ChatGPT 待归属的明细归属到账号（chatgpt-profiles ticket 09，spec "会话 → 档案归属顺序"）：
// 会话 → 档案 → 档案此刻登录的账号。只管 ChatGPT 的会话（TokenLedger.pendingSessions(tool: .chatgpt)），
// Claude 的由 SessionAttribution 管，互不碰。
//
// 会话 → 档案，依次：
//   ① 写这个会话的进程（ChatGPTSessionWriters：打开着它的写入锁或会话记录的 codex 进程）环境里的 CODEX_HOME。
//      找到时把"会话 → 档案、观察时刻"记进账本（chatgpt_sessions），App 重启后、进程退出后仍可用——
//      桌面 App 不写 history.jsonl，它的会话只能靠这份记录。CODEX_HOME 是 cc-pilot 管理范围以外的目录时
//      直接记为未归属（确定不是任何档案的）。
//   ② 找不到进程时：记着的观察结果，与各档案 history.jsonl 里这个会话最新的一行，哪个时间更新用哪个
//      （App 没开时会话可能在另一个档案的 codex 里 resume 了）。几个档案的 history.jsonl 都有时取最新一行所在
//      的档案，时间相同时按档案列表顺序取前一个。子代理会话自己找不到时按父线程找。
//   ③ 都找不到：会话里最新一条待归属明细过了 grace（1 小时）仍找不到才记为未归属。
// 档案 → 账号：归属时该档案登录的账号（ChatGPTProfile.usageAccount，"chatgpt:<用户 ID>:<工作区 ID>"）。
// 档案没有可用的账号（未登录、API key、读不懂）时先不下结论，过了 grace 记为未归属（同 Claude 侧）。
// 只改待归属的明细：共享会话在另一个档案里 resume 后，之前的明细仍算原账号，之后的算新档案的。
//
// session_meta 的 creator_user_id 只用于校验，不改变归属：共享会话（ADR 0006）在另一个档案里 resume 时，
// 创建者仍是原来的用户，与写入者的账号不一致是正常的；进程与 history.jsonl 是更直接的证据。
// 不一致时不报错、不记日志（日志里不写账号信息）；记在账本里留给以后核对。
//
// history.jsonl（每个档案一份，codex 每提交一次输入记一行 {"session_id", "ts"（秒）, "text"}）增量读取，
// 索引只在内存里，App 启动后第一次归属时读全量。没有待归属的会话时什么也不读。
// 只在一个线程（或串行队列）上使用；writers 与实时额度共用时也在同一个队列上。

import Foundation

final class ChatGPTSessionAttribution {
    private let environment: CoreEnvironment
    private let writers: ChatGPTSessionWriters
    private let grace: TimeInterval
    private let now: () -> Date
    /// history.jsonl 路径 → 读取状态
    private var histories: [String: ChatGPTHistoryIndex] = [:]

    /// - writers: 进行中会话的写入者；实时额度（ChatGPTLiveQuotaTracker）用同一个实例可以共用查询结果
    init(environment: CoreEnvironment, writers: ChatGPTSessionWriters? = nil,
         grace: TimeInterval = SessionAttribution.defaultGrace, now: @escaping () -> Date = Date.init) {
        self.environment = environment
        self.writers = writers ?? ChatGPTSessionWriters(environment: environment)
        self.grace = grace
        self.now = now
    }

    /// 给账本里所有 ChatGPT 待归属的会话定归属（TokenUsageRecorder 的归属钩子之一）
    func attribute(_ ledger: TokenLedger) throws {
        let pending = try ledger.pendingSessions(tool: .chatgpt)
        guard !pending.isEmpty else { return }
        let store = ChatGPTProfileStore(environment: environment)
        let paths = ChatGPTProfilePaths(environment: environment)
        let names = store.allProfileNames()
        let historyPaths = names.map { paths.directory(forProfileNamed: $0) + "/history.jsonl" }
        // 已经不是档案的 history.jsonl 不再参与
        histories = histories.filter { historyPaths.contains($0.key) }
        let indexes = historyPaths.map { path -> ChatGPTHistoryIndex in
            let index = histories[path] ?? ChatGPTHistoryIndex()
            index.update(path: path)
            histories[path] = index
            return index
        }
        /// 一个会话在各档案 history.jsonl 里最新的一行：（档案，时间）
        func newestHistory(_ session: String) -> (profile: String, at: Date)? {
            var best: (profile: String, at: Date)?
            for (name, index) in zip(names, indexes) {
                guard let ts = index.sessions[session] else { continue }
                if best == nil || ts > best!.at { best = (name, ts) }
            }
            return best
        }
        /// ② 记着的观察结果与 history.jsonl 取较新的；自己找不到时按父线程找
        func remembered(_ session: String) throws -> String? {
            var record = try ledger.chatgptSession(session)
            var id = session
            for _ in 0..<2 {
                let candidates = [record?.observed, newestHistory(id)].compactMap { $0 }
                if let newest = candidates.max(by: { $0.at < $1.at }) { return newest.profile }
                guard let parent = record?.parentSessionID, parent != id else { break }
                id = parent
                record = try ledger.chatgptSession(parent)
            }
            return nil
        }

        // 这一次里各档案的账号（同一次里不重复读 auth.json）
        var accounts: [String: UsageAccount?] = [:]
        func account(of name: String) -> UsageAccount? {
            if let cached = accounts[name] { return cached }
            let account = store.profile(named: name).usageAccount
            accounts[name] = account
            return account
        }

        let found = writers.writers(of: Set(pending.map(\.sessionID)))
        let deadline = now().addingTimeInterval(-grace)
        for session in pending {
            let id = session.sessionID
            let profile: String?
            switch found[id] ?? .notFound {
            case .profile(let name):
                if try ledger.chatgptSession(id)?.observed?.profile != name {
                    try ledger.recordChatGPTWriter(sessionID: id, profile: name, at: now())
                }
                profile = name
            case .external:
                try ledger.attribute(sessionID: id, as: .unattributed, tool: .chatgpt)
                continue
            case .notFound:
                profile = try remembered(id)
            }
            if let profile, let account = account(of: profile) {
                try ledger.attribute(sessionID: id, as: .attributed(profile: profile, account: account.id), tool: .chatgpt)
            } else if session.latest < deadline {
                try ledger.attribute(sessionID: id, as: .unattributed, tool: .chatgpt)
            }
        }
    }
}

/// 一份 ChatGPT history.jsonl 里出现过的会话，及各会话最新一行的时间
private final class ChatGPTHistoryIndex {
    private(set) var sessions: [String: Date] = [:]
    private var position: FilePosition?

    func update(path: String) {
        let read: AppendedLines?
        do { read = try AppendedLines(path: path, after: position) } catch { return }  // 读不出来：下次再试
        guard let read else {
            // 文件没了才清空；只是一时打不开时留着，下次再试
            if !FileManager.default.fileExists(atPath: path) { (sessions, position) = ([:], nil) }
            return
        }
        if read.start == 0 { sessions = [:] }
        for line in read.lines {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let session = object["session_id"] as? String, !session.isEmpty
            else { continue }
            let ts = Date(timeIntervalSince1970: (object["ts"] as? NSNumber)?.doubleValue ?? 0)
            sessions[session] = max(sessions[session] ?? ts, ts)
        }
        position = read.position
    }
}
