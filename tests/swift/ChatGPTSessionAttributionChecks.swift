// chatgpt-profiles ticket 09：账本里 ChatGPT 的明细按 会话 → 档案 → 档案此刻登录的账号 归属。
//
// 检查的接口（seam）：ChatGPTSessionAttribution(environment:writers:grace:now:).attribute(ledger)，
// 结果从 TokenLedger.messages() 读。会话记录、history.jsonl、进程都是合成的（CodexRolloutFixtures、
// FakeCodexProcesses），不涉及文件监听。期望值来自 spec "会话 → 档案归属顺序"：
//   ① 写这个会话的进程的 CODEX_HOME；② 各档案 history.jsonl 的 session_id，取最新一行所在档案；
//   ③ ①② 都没有证据时，会话 1 小时没有新事件后按 session_meta 的 creator_user_id 归到唯一对应的账号，
//   对应不到或对应几个时记为未归属（spec Comments 2026-11-05 的决定）。观察到的归属持久化。
//   账号键 "chatgpt:<用户>:<工作区>"。

import Foundation

final class ChatGPTSessionAttributionChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("① 写这个会话的进程在哪个档案，就归到那个档案此刻登录的账号", attributesByWriterProcess),
            Check("观察到的归属记进账本：重启后进程已退出，之后的事件仍归到那个档案（桌面 App 的会话只能靠它）",
                  persistsObservedWriter),
            Check("② 找不到进程时按各档案的 history.jsonl，取最新一行所在的档案", attributesByNewestHistory),
            Check("记着的归属和 history.jsonl 哪个更新用哪个（App 没开时会话在别的档案里 resume）",
                  newerOfObservedAndHistoryWins),
            Check("③ 都找不到：会话 1 小时没有新事件前先等着，之后按创建者归到唯一对应的账号",
                  attributesByCreatorAfterGrace),
            Check("③ 创建者对应不到任何档案的账号：1 小时后记为未归属", unknownSessionBecomesUnattributed),
            Check("③ 创建者对应几个账号（同一用户的不同工作区）：记为未归属", ambiguousCreatorIsUnattributed),
            Check("③ 几个档案登录了创建者的同一个账号：归到这个账号，档案取列表里的第一个",
                  creatorAccountInSeveralProfiles),
            Check("有 ① 写入进程的证据时不看创建者，即使两者账号不同", writerBeatsCreator),
            Check("有 ② history.jsonl 的证据时不看创建者，即使两者账号不同；档案没有账号时也不改看创建者",
                  historyBeatsCreator),
            Check("写入进程是外部目录的会话，进程退出后的事件也不按创建者归属", externalWriterBeatsCreatorLater),
            Check("以前已经记为未归属的明细也按创建者重新归属（有 ①② 证据的不动）", reattributesOldUnattributed),
            Check("Claude 的归属器不碰 ChatGPT 的待归属会话，反之亦然", toolsDoNotTouchEachOther),
            Check("档案没有可用的账号时先等着，等待期内登录就归属，过了等待期记为未归属", waitsWhileAccountMissing),
            Check("写入进程的 CODEX_HOME 是外部目录：记为未归属", externalWriterIsUnattributed),
            Check("共享会话在另一个档案里 resume：之前的仍算原账号，之后的算新档案的"
                  + "（有写入进程时不看 creator_user_id）", resumedElsewhereMovesNewEvents),
            Check("子代理会话随父线程的归属", subagentFollowsParent),
            Check("③ 子代理会话自己没有创建者时，看父会话的创建者", subagentUsesParentCreator),
        ]
    }

    static let session = "019a4f00-0000-7000-8000-0000000000a1"
    static let other = "019a4f00-0000-7000-8000-0000000000b2"
    static let child = "019a4f00-0000-7000-8000-0000000000c3"
    /// 2026-11-04T10:00:00Z
    static let start = Date(timeIntervalSince1970: 1_793_786_400)
    static let workAccount = "chatgpt:user-w:ws-1"
    static let defaultAccount = "chatgpt:user-d:ws-1"

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// 临时主目录 + 账本：默认档案登录 user-d，work 档案登录 user-w（同一工作区）
    final class Env {
        let home: TempHome
        var ledger: TokenLedger
        var clock = ChatGPTSessionAttributionChecks.at(5)

        init() throws {
            home = try TempHome()
            try home.makeCodexDefault(auth: chatgptAuth(email: "d@example.com", userID: "user-d", workspaceID: "ws-1"))
            try home.makeCodexProfile("work", auth: chatgptAuth(email: "w@example.com", userID: "user-w", workspaceID: "ws-1"))
            ledger = try TokenLedger(at: TokenLedger.defaultURL(environment: home.environment))
        }

        func remove() { home.remove() }

        var codexHome: String { home.url.path + "/.codex-profiles/work" }
        func lock(_ id: String) -> String { home.url.path + "/.codex/thread-writer-locks/\(id).lock" }

        /// 写一份会话记录：首行 session_meta，之后每分钟数一次用量
        func rollout(_ id: String, creator: String? = "user-w", parent: String? = nil, events minutes: [Double],
                     input: Int = 10) throws {
            var meta = CodexRollout.meta(id: id, at: iso(start), creatorUserID: creator)
            if let parent {
                // 子代理：source.subagent.thread_spawn.parent_thread_id
                meta = meta.replacingOccurrences(of: #""source":"cli""#, with:
                    #""source":{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parent)"}}}"#)
            }
            try home.write(CodexRollout.path(id), CodexRollout.file([meta, CodexRollout.turnContext(model: "gpt-5.3-codex", at: iso(start))]
                + minutes.map { tokenCount($0, input: input) }))
        }

        func tokenCount(_ minute: Double, input: Int = 10) -> String {
            // total 随时间变，去重键各不相同
            CodexRollout.tokenCount(at: iso(at(minute)), last: .init(input: input, output: 1),
                                    total: .init(input: input + Int(minute * 1000), output: 1))
        }

        func appendEvents(_ id: String, _ minutes: [Double], input: Int = 10) throws {
            let handle = try FileHandle(forWritingTo: home.url.appendingPathComponent(CodexRollout.path(id)))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(CodexRollout.file(minutes.map { tokenCount($0, input: input) }).utf8))
        }

        /// 往档案的 history.jsonl 追加一行（profile 为 nil 是默认档案）
        func history(_ profile: String?, _ id: String, at minute: Double) throws {
            let path = (profile.map { ".codex-profiles/\($0)" } ?? ".codex") + "/history.jsonl"
            let line = #"{"session_id":"\#(id)","ts":\#(Int(at(minute).timeIntervalSince1970)),"text":"hi"}"# + "\n"
            let url = home.url.appendingPathComponent(path)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try home.write(path, line)
            }
        }

        func ingest() throws {
            let scan = CodexSessionReader(environment: home.environment).scan(try ledger.chatgptCursors())
            try ledger.ingest(chatgpt: scan)
        }

        func attribution(writers: ChatGPTSessionWriters? = nil) -> ChatGPTSessionAttribution {
            ChatGPTSessionAttribution(environment: home.environment, writers: writers, now: { [unowned self] in clock })
        }

        /// 每条明细的归属，按时间
        func attributions() throws -> [LedgerAttribution] {
            try ledger.messages().map(\.attribution)
        }
    }

    static func work(_ account: String = workAccount) -> LedgerAttribution {
        .attributed(profile: "work", account: account)
    }

    static let byDefault = LedgerAttribution.attributed(profile: "default", account: defaultAccount)

    // MARK: - ① 进程

    static func attributesByWriterProcess() throws {
        let env = try Env()
        defer { env.remove() }
        env.home.codexProcesses.run(pid: 42, home: .path(env.codexHome), files: [env.lock(session)])
        try env.rollout(session, events: [1, 2])
        try env.ingest()
        try env.attribution().attribute(env.ledger)
        try expectEqual(try env.attributions(), [work(), work()])
    }

    static func persistsObservedWriter() throws {
        let env = try Env()
        defer { env.remove() }
        // 桌面 App（默认档案）在写：它不写 history.jsonl
        let app = env.home.codexProcesses.run(pid: 7, home: .unset, files: [env.lock(session)])
        try env.rollout(session, events: [1])
        try env.ingest()
        try env.attribution().attribute(env.ledger)
        try expectEqual(try env.attributions(), [byDefault])

        // App 重启：进程已经退出，App 没开时写下的事件
        env.home.codexProcesses.exit(app)
        try env.appendEvents(session, [3, 4])
        env.ledger = try TokenLedger(at: TokenLedger.defaultURL(environment: env.home.environment))
        try env.ingest()
        try env.attribution().attribute(env.ledger)
        try expectEqual(try env.attributions(), [byDefault, byDefault, byDefault])
    }

    // MARK: - ② history.jsonl

    static func attributesByNewestHistory() throws {
        let env = try Env()
        defer { env.remove() }
        try env.rollout(session, events: [1, 2])
        try env.rollout(other, events: [1])
        try env.history(nil, session, at: 0)
        try env.history("work", session, at: 1)
        try env.history("work", other, at: 0)
        try env.history(nil, other, at: 0.5)
        try env.ingest()
        try env.attribution().attribute(env.ledger)
        let messages = try env.ledger.messages()
        try expectEqual(messages.filter { $0.sessionID == session }.map(\.attribution), [work(), work()])
        try expectEqual(messages.filter { $0.sessionID == other }.map(\.attribution), [byDefault])
    }

    static func newerOfObservedAndHistoryWins() throws {
        let env = try Env()
        defer { env.remove() }
        // work 档案的进程在写，App 记下了
        let process = env.home.codexProcesses.run(pid: 42, home: .path(env.codexHome), files: [env.lock(session)])
        try env.rollout(session, events: [1])
        try env.ingest()
        try env.attribution().attribute(env.ledger)
        env.home.codexProcesses.exit(process)

        // App 没开时，会话在默认档案的 codex 里 resume（history.jsonl 有更新的一行）
        env.clock = at(30)
        try env.history(nil, session, at: 20)
        try env.appendEvents(session, [21])
        env.ledger = try TokenLedger(at: TokenLedger.defaultURL(environment: env.home.environment))
        try env.ingest()
        try env.attribution().attribute(env.ledger)
        try expectEqual(try env.attributions(), [work(), byDefault])

        // history.jsonl 比记着的旧：仍按记着的
        let env2 = try Env()
        defer { env2.remove() }
        try env2.history(nil, session, at: 0)
        let p2 = env2.home.codexProcesses.run(pid: 43, home: .path(env2.codexHome), files: [env2.lock(session)])
        try env2.rollout(session, events: [1])
        try env2.ingest()
        try env2.attribution().attribute(env2.ledger)
        env2.home.codexProcesses.exit(p2)
        try env2.appendEvents(session, [2])
        try env2.ingest()
        try env2.attribution().attribute(env2.ledger)
        try expectEqual(try env2.attributions(), [work(), work()])
    }

    // MARK: - ③ 未归属

    static func attributesByCreatorAfterGrace() throws {
        let env = try Env()
        defer { env.remove() }
        // Zed（codex-acp）、桌面 App 的会话：CC Pilot 没在运行，没有写入进程的记录，也不写 history.jsonl
        try env.rollout(session, creator: "user-w", events: [1, 2])
        try env.ingest()
        let attribution = env.attribution()
        env.clock = at(2 + 59)
        try attribution.attribute(env.ledger)
        try expectEqual(try env.attributions(), [.pending, .pending], "最新事件之后不到 1 小时")
        env.clock = at(2 + 61)
        try attribution.attribute(env.ledger)
        try expectEqual(try env.attributions(), [work(), work()])
    }

    static func unknownSessionBecomesUnattributed() throws {
        let env = try Env()
        defer { env.remove() }
        try env.rollout(session, creator: "user-x", events: [1, 2])
        try env.ingest()
        let attribution = env.attribution()
        env.clock = at(2 + 59)
        try attribution.attribute(env.ledger)
        try expectEqual(try env.attributions(), [.pending, .pending], "最新事件之后不到 1 小时")
        env.clock = at(2 + 61)
        try attribution.attribute(env.ledger)
        try expectEqual(try env.attributions(), [.unattributed, .unattributed])
        try expectEqual(try env.ledger.cumulativeUsage(account: workAccount).usage.tokens, .zero)
    }

    static func ambiguousCreatorIsUnattributed() throws {
        let env = try Env()
        defer { env.remove() }
        // user-w 还在另一个工作区：creator_user_id 只有用户 ID，分不出是哪个工作区
        try env.home.makeCodexProfile("team", auth: chatgptAuth(email: "w@example.com", userID: "user-w", workspaceID: "ws-2"))
        try env.rollout(session, creator: "user-w", events: [1])
        try env.ingest()
        env.clock = at(62)
        try env.attribution().attribute(env.ledger)
        try expectEqual(try env.attributions(), [.unattributed])
    }

    static func creatorAccountInSeveralProfiles() throws {
        let env = try Env()
        defer { env.remove() }
        // alpha 与 work 登录同一个账号（同一用户、同一工作区）：列表顺序是 default、alpha、work
        try env.home.makeCodexProfile("alpha", auth: chatgptAuth(email: "w@example.com", userID: "user-w", workspaceID: "ws-1"))
        try env.rollout(session, creator: "user-w", events: [1])
        try env.ingest()
        env.clock = at(62)
        try env.attribution().attribute(env.ledger)
        try expectEqual(try env.attributions(), [.attributed(profile: "alpha", account: workAccount)])
    }

    static func writerBeatsCreator() throws {
        let env = try Env()
        defer { env.remove() }
        // user-w 创建的会话由默认档案（user-d）的进程在写
        env.home.codexProcesses.run(pid: 50, home: .unset, files: [env.lock(session)])
        try env.rollout(session, creator: "user-w", events: [1])
        try env.ingest()
        env.clock = at(62)
        try env.attribution().attribute(env.ledger)
        try expectEqual(try env.attributions(), [byDefault])
    }

    static func historyBeatsCreator() throws {
        let env = try Env()
        defer { env.remove() }
        try env.history(nil, session, at: 0)
        try env.rollout(session, creator: "user-w", events: [1])
        try env.ingest()
        env.clock = at(62)
        try env.attribution().attribute(env.ledger)
        try expectEqual(try env.attributions(), [byDefault])

        // history.jsonl 说是 work 档案，它用 API key 登录、没有账号：仍记为未归属，不改按创建者（user-d）
        let env2 = try Env()
        defer { env2.remove() }
        try env2.home.writeJSON(".codex-profiles/work/auth.json", apiKeyAuth())
        try env2.history("work", session, at: 0)
        try env2.rollout(session, creator: "user-d", events: [1])
        try env2.ingest()
        env2.clock = at(62)
        try env2.attribution().attribute(env2.ledger)
        try expectEqual(try env2.attributions(), [.unattributed])
    }

    static func externalWriterBeatsCreatorLater() throws {
        let env = try Env()
        defer { env.remove() }
        let process = env.home.codexProcesses.run(pid: 42, home: .path("/opt/elsewhere/codex"), files: [env.lock(session)])
        try env.rollout(session, creator: "user-w", events: [1])
        try env.ingest()
        let attribution = env.attribution()
        try attribution.attribute(env.ledger)
        try expectEqual(try env.attributions(), [.unattributed])
        // 外部进程退出后又写了一些（CC Pilot 没看到是谁写的），重启后过了等待期
        env.home.codexProcesses.exit(process)
        try env.appendEvents(session, [3])
        env.ledger = try TokenLedger(at: TokenLedger.defaultURL(environment: env.home.environment))
        try env.ingest()
        env.clock = at(70)
        try env.attribution().attribute(env.ledger)
        try expectEqual(try env.attributions(), [.unattributed, .unattributed])
    }

    static func reattributesOldUnattributed() throws {
        let env = try Env()
        defer { env.remove() }
        // 以前的版本不看创建者：没有证据的会话过了等待期记为未归属；
        // other 在 work 档案里写（history.jsonl），那时 work 用 API key 登录、没有账号，也记为未归属
        try env.rollout(session, creator: "user-w", events: [1, 2])
        try env.rollout(other, creator: "user-d", events: [1])
        try env.history("work", other, at: 0)
        try env.ingest()
        try env.ledger.attribute(sessionID: session, as: .unattributed, tool: .chatgpt)
        try env.ledger.attribute(sessionID: other, as: .unattributed, tool: .chatgpt)
        env.clock = at(200)
        try env.attribution().attribute(env.ledger)
        let messages = try env.ledger.messages()
        try expectEqual(messages.filter { $0.sessionID == session }.map(\.attribution), [work(), work()])
        try expectEqual(messages.filter { $0.sessionID == other }.map(\.attribution), [.unattributed])
    }

    static func toolsDoNotTouchEachOther() throws {
        let env = try Env()
        defer { env.remove() }
        try env.rollout(session, creator: nil, events: [1])
        try env.ingest()
        try env.home.write(".claude/projects/p/s-claude.jsonl", TranscriptFixture.file([
            TranscriptFixture.assistant(id: "msg_c", session: "s-claude", at: iso(at(1)), output: 3),
        ]))
        try env.ledger.ingest(projectsRoot: env.home.url.appendingPathComponent(".claude/projects"))
        // 都过了等待期、都找不到归属
        let late = at(200)
        try SessionAttribution(environment: env.home.environment, now: { late }).attribute(env.ledger)
        let chatgpt = try env.ledger.messages().filter { $0.tool == .chatgpt }
        try expectEqual(chatgpt.map(\.attribution), [.pending], "Claude 的归属器不把 ChatGPT 的会话记成未归属")
        env.clock = late
        try env.attribution().attribute(env.ledger)
        let claude = try env.ledger.messages().filter { $0.tool == .claudeCode }
        try expectEqual(claude.map(\.attribution), [.unattributed])
        try expectEqual(try env.ledger.messages().filter { $0.tool == .chatgpt }.map(\.attribution), [.unattributed])
    }

    static func waitsWhileAccountMissing() throws {
        let env = try Env()
        defer { env.remove() }
        // work 档案还没登录
        try FileManager.default.removeItem(at: env.home.codexProfilesRoot.appendingPathComponent("work/auth.json"))
        env.home.codexProcesses.run(pid: 42, home: .path(env.codexHome), files: [env.lock(session)])
        try env.rollout(session, events: [1])
        try env.rollout(other, events: [1])
        env.home.codexProcesses.run(pid: 43, home: .path(env.codexHome), files: [env.lock(other)])
        try env.ingest()
        let attribution = env.attribution()
        try attribution.attribute(env.ledger)
        try expectEqual(try env.attributions(), [.pending, .pending])
        // 等待期内登录了
        try env.home.writeJSON(".codex-profiles/work/auth.json",
                               chatgptAuth(email: "w@example.com", userID: "user-w", workspaceID: "ws-1"))
        try attribution.attribute(env.ledger)
        try expectEqual(try env.attributions(), [work(), work()])

        // API key 登录的档案永远没有账号：过了等待期记为未归属
        let env2 = try Env()
        defer { env2.remove() }
        try env2.home.writeJSON(".codex-profiles/work/auth.json", apiKeyAuth())
        env2.home.codexProcesses.run(pid: 42, home: .path(env2.codexHome), files: [env2.lock(session)])
        try env2.rollout(session, events: [1])
        try env2.ingest()
        try env2.attribution().attribute(env2.ledger)
        try expectEqual(try env2.attributions(), [.pending])
        env2.clock = at(62)
        try env2.attribution().attribute(env2.ledger)
        try expectEqual(try env2.attributions(), [.unattributed])
    }

    static func externalWriterIsUnattributed() throws {
        let env = try Env()
        defer { env.remove() }
        env.home.codexProcesses.run(pid: 42, home: .path("/opt/elsewhere/codex"), files: [env.lock(session)])
        // 外部目录的会话碰巧也出现在 work 的 history.jsonl 里：进程更直接，仍不归属
        try env.history("work", session, at: 0)
        try env.rollout(session, events: [1])
        try env.ingest()
        try env.attribution().attribute(env.ledger)
        try expectEqual(try env.attributions(), [.unattributed])
    }

    static func resumedElsewhereMovesNewEvents() throws {
        let env = try Env()
        defer { env.remove() }
        // work 档案（user-w）创建并写了会话
        let first = env.home.codexProcesses.run(pid: 42, home: .path(env.codexHome), files: [env.lock(session)])
        try env.rollout(session, creator: "user-w", events: [1])
        try env.ingest()
        let attribution = env.attribution()
        try attribution.attribute(env.ledger)
        // 共享会话在默认档案（user-d）里 resume：creator_user_id 仍是 user-w
        env.home.codexProcesses.exit(first)
        env.home.codexProcesses.run(pid: 50, home: .unset, files: [env.lock(session)])
        try env.appendEvents(session, [10])
        try env.ingest()
        try attribution.attribute(env.ledger)
        try expectEqual(try env.attributions(), [work(), byDefault])
    }

    static func subagentFollowsParent() throws {
        let env = try Env()
        defer { env.remove() }
        // 父会话在 work 的 history.jsonl 里；子代理会话自己不在任何 history.jsonl 里，写它的进程已退出
        try env.history("work", session, at: 0)
        try env.rollout(session, events: [1])
        try env.rollout(child, parent: session, events: [2])
        try env.ingest()
        try env.attribution().attribute(env.ledger)
        let messages = try env.ledger.messages()
        try expectEqual(messages.filter { $0.sessionID == child }.map(\.attribution), [work()])
    }

    static func subagentUsesParentCreator() throws {
        let env = try Env()
        defer { env.remove() }
        try env.rollout(session, creator: "user-w", events: [1])
        try env.rollout(child, creator: nil, parent: session, events: [2])
        try env.ingest()
        env.clock = at(63)
        try env.attribution().attribute(env.ledger)
        let messages = try env.ledger.messages()
        try expectEqual(messages.filter { $0.sessionID == child }.map(\.attribution), [work()])
    }
}
