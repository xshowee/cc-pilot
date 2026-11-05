// 把账本里 ChatGPT 待归属的明细归属到账号（chatgpt-profiles ticket 09，spec "会话 → 档案归属顺序"）：
// 会话 → 档案 → 档案此刻登录的账号。只管 ChatGPT 的会话（TokenLedger.pendingSessions(tool: .chatgpt)），
// Claude 的由 SessionAttribution 管，互不碰。
//
// 会话 → 档案，依次：
//   ① 写这个会话的进程（ChatGPTSessionWriters：打开着它的写入锁或会话记录的 codex 进程）环境里的 CODEX_HOME。
//      找到时把"会话 → 档案、观察时刻"记进账本（chatgpt_sessions），App 重启后、进程退出后仍可用。
//      CODEX_HOME 是 cc-pilot 管理范围以外的目录时直接记为未归属（确定不是任何档案的），也记进账本
//      （档案为空），进程退出后之后的事件也不会因为没有证据而落到 ③。
//   ② 找不到进程时：记着的观察结果，与各档案 history.jsonl 里这个会话最新的一行，哪个时间更新用哪个
//      （App 没开时会话可能在另一个档案的 codex 里 resume 了）。几个档案的 history.jsonl 都有时取最新一行所在
//      的档案，时间相同时按档案列表顺序取前一个。子代理会话自己找不到时按父线程找。
//   ③ ①② 都没有证据：会话里最新一条待归属明细过了 grace（1 小时）后，按 session_meta 的 creator_user_id
//      （创建会话的用户 ID；不是 creator_account_id，后者是工作区 ID）归属：这个用户 ID 在现有档案的账号里
//      恰好对应一个账号（"chatgpt:<用户 ID>:<工作区 ID>" 的用户 ID 部分相同）时归到这个账号；对应不到、
//      或对应几个（同一用户的几个工作区）时记为未归属。子代理会话自己没有创建者时看父线程的。
//      桌面 App 和 Zed（codex-acp）都不写 history.jsonl，CC Pilot 没运行时它们的会话只能靠这一步。
//      几个档案登录了这个账号时，记进账本的档案取档案列表里的第一个（同 ② 时间相同时、额度刷新取凭据时的做法）。
//      接受的风险（spec Comments 2026-11-05）：共享会话（ADR 0006）在别的账号的档案里续用、而当时 CC Pilot
//      没在运行时，续用部分算到创建者名下。①② 有证据时不看创建者：共享会话在另一个档案里 resume 时，
//      创建者仍是原来的用户，与写入者的账号不一致是正常的。
// 档案 → 账号：归属时该档案登录的账号（ChatGPTProfile.usageAccount，"chatgpt:<用户 ID>:<工作区 ID>"）。
// ①② 找到的档案没有可用的账号（未登录、API key、读不懂）时先不下结论，过了 grace 记为未归属（同 Claude 侧），
// 不改按创建者。
// 只改待归属的明细：共享会话在另一个档案里 resume 后，之前的明细仍算原账号，之后的算新档案的。
//
// 以前的版本没有 ③，过了 grace 就记为未归属。这些明细在升级后第一次归属时按 ③ 重新看一次（只看一次，
// 账本 meta 的 chatgpt_creator_backfill 记着已经看过）：①② 有证据的不动，其余按创建者对应到唯一账号的归过去。
// 以前的版本不记外部目录的写入者，那样的会话这时分不出来，也会按创建者归属。
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

    /// ①② 找到的写入者
    private enum Evidence: Equatable {
        case profile(String)
        /// cc-pilot 管理范围以外的 CODEX_HOME
        case external
    }

    /// - writers: 进行中会话的写入者；实时额度（ChatGPTLiveQuotaTracker）用同一个实例可以共用查询结果
    init(environment: CoreEnvironment, writers: ChatGPTSessionWriters? = nil,
         grace: TimeInterval = SessionAttribution.defaultGrace, now: @escaping () -> Date = Date.init) {
        self.environment = environment
        self.writers = writers ?? ChatGPTSessionWriters(environment: environment)
        self.grace = grace
        self.now = now
    }

    /// 给账本里所有 ChatGPT 待归属的会话定归属（TokenUsageRecorder 的归属钩子之一）；
    /// 升级后第一次时也按创建者重新看以前记为未归属的会话
    func attribute(_ ledger: TokenLedger) throws {
        let pending = try ledger.pendingSessions(tool: .chatgpt)
        let backfill = try ledger.chatgptCreatorBackfillDone() ? nil : try ledger.unattributedSessions(tool: .chatgpt)
        guard !pending.isEmpty || !(backfill ?? []).isEmpty else {
            if backfill != nil { try ledger.markChatGPTCreatorBackfillDone(at: now()) }
            return
        }
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
        func newestHistory(_ session: String) -> (evidence: Evidence, at: Date)? {
            var best: (evidence: Evidence, at: Date)?
            for (name, index) in zip(names, indexes) {
                guard let ts = index.sessions[session] else { continue }
                if best == nil || ts > best!.at { best = (.profile(name), ts) }
            }
            return best
        }
        /// ② 记着的观察结果与 history.jsonl 取较新的；自己找不到时按父线程找
        func remembered(_ session: String) throws -> Evidence? {
            var record = try ledger.chatgptSession(session)
            var id = session
            for _ in 0..<2 {
                let observed = record?.observed.map { (evidence: $0.profile.map(Evidence.profile) ?? .external, at: $0.at) }
                let candidates = [observed, newestHistory(id)].compactMap { $0 }
                if let newest = candidates.max(by: { $0.at < $1.at }) { return newest.evidence }
                guard let parent = record?.parentSessionID, parent != id else { break }
                id = parent
                record = try ledger.chatgptSession(parent)
            }
            return nil
        }

        // 这一次里各档案的账号（同一次里不重复读 auth.json）
        var keys: [String: ChatGPTAccountKey?] = [:]
        func key(of name: String) -> ChatGPTAccountKey? {
            if let cached = keys[name] { return cached }
            let key = store.profile(named: name).account?.key
            keys[name] = key
            return key
        }
        func account(of name: String) -> UsageAccount? { key(of: name)?.usageAccount }
        /// ③ 按创建者：创建者恰好对应一个账号时归到它（档案取列表里第一个登录它的），否则未归属
        func byCreator(_ session: String) throws -> LedgerAttribution {
            let record = try ledger.chatgptSession(session)
            var creator = record?.creatorUserID
            if creator?.isEmpty ?? true, let parent = record?.parentSessionID, parent != session {
                creator = try ledger.chatgptSession(parent)?.creatorUserID
            }
            guard let creator, !creator.isEmpty else { return .unattributed }
            let matching = names.filter { key(of: $0)?.userID == creator }
            // 同一用户的几个工作区是几个账号，分不出是哪个
            guard Set(matching.compactMap { key(of: $0) }).count == 1, let profile = matching.first,
                  let account = account(of: profile) else { return .unattributed }
            return .attributed(profile: profile, account: account.id)
        }

        /// ① 记下观察到的写入者（与记着的相同时不重写）：App 重启后、进程退出后仍可用
        func remember(_ session: String, profile: String?) throws {
            if let observed = try ledger.chatgptSession(session)?.observed, observed.profile == profile { return }
            try ledger.recordChatGPTWriter(sessionID: session, profile: profile, at: now())
        }

        let found = writers.writers(of: Set(pending.map(\.sessionID)))
        let deadline = now().addingTimeInterval(-grace)
        for session in pending {
            let id = session.sessionID
            let evidence: Evidence?
            switch found[id] ?? .notFound {
            case .profile(let name):
                try remember(id, profile: name)
                evidence = .profile(name)
            case .external:
                try remember(id, profile: nil)
                try ledger.attribute(sessionID: id, as: .unattributed, tool: .chatgpt)
                continue
            case .notFound:
                evidence = try remembered(id)
            }
            if case .profile(let profile) = evidence, let account = account(of: profile) {
                try ledger.attribute(sessionID: id, as: .attributed(profile: profile, account: account.id), tool: .chatgpt)
            } else if session.latest < deadline {
                try ledger.attribute(sessionID: id, as: evidence == nil ? try byCreator(id) : .unattributed,
                                     tool: .chatgpt)
            }
        }
        for session in backfill ?? [] {
            let id = session.sessionID
            guard try remembered(id) == nil else { continue }
            let attribution = try byCreator(id)
            if attribution != .unattributed {
                try ledger.attribute(sessionID: id, as: attribution, tool: .chatgpt, replacing: .unattributed)
            }
        }
        if backfill != nil { try ledger.markChatGPTCreatorBackfillDone(at: now()) }
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
