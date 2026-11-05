// chatgpt-profiles ticket 09：TokenUsageRecorder 跟着 ChatGPT 会话记录（唯一的读取器与监视器）记账、归属，
// 同一次扫描的事件再交给实时额度。用真实文件系统事件，每一步最多等 5 秒；进程是假的（FakeCodexProcesses）。
//
// 检查的接口（seam）：TokenUsageRecorder(environment:…, followsChatGPT: true, onChatGPTLiveQuota:)
// 的 start / read / stop，结果从账本读。

import Foundation

final class ChatGPTTokenUsageRecorderChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("启动时读入 ChatGPT 会话记录并归属；之后追加的自动读入；同一批事件的实时额度交给回调",
                  followsChatGPTSessions),
            Check("重启后从账本记着的位置接着读，不重复计入", resumesFromStoredCursors),
            Check("记入账本失败时读取位置不前进，之后重读这一批，不漏记", rereadsAfterFailedIngest),
            Check("记入账本失败后，下一次扫描（不管哪个目录有变化）全量扫描：已经结束的会话的那一批也读回来",
                  fullScanAfterFailedIngest),
            Check("Claude 一侧的同步也会重试 ChatGPT 的归属（没有新的 ChatGPT 事件也能过等待期）",
                  claudeSyncRetriesChatGPTAttribution),
            Check("一次扫描（归属 + 实时额度）只列一次进程、只查一次打开的文件；没有待归属会话、没有额度时不列",
                  listsProcessesOncePerScan),
            Check("重启后按账本补回各账号最近的一份额度：写入进程已退出也行，用事件自己的时间，不列进程",
                  restoresQuotaAfterRestart),
            Check("补回额度只取最近一条已归属用量之后、同一会话下一条用量之前的；会话转到别的账号后各补各的；没归属的不补",
                  restoreStopsAtNextUsage),
        ]
    }

    typealias A = ChatGPTSessionAttributionChecks

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T
        init(_ value: T) { stored = value }
        var value: T {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    static func makeRecorder(_ env: A.Env, now: Box<Date>, quotas: Box<[UsageAccount: LiveQuota]>? = nil,
                             updates: ProfileWatcherChecks.Counter? = nil) -> TokenUsageRecorder {
        TokenUsageRecorder(environment: env.home.environment, latency: 0.05,
                           calendar: TokenLedgerRollupChecks.calendar, now: { now.value },
                           followsChatGPT: true,
                           onChatGPTLiveQuota: { received in
                               guard let quotas else { return }
                               quotas.value.merge(received) { $1 }
                           },
                           onUpdate: { updates?.increment() })
    }

    static func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    static func followsChatGPTSessions() throws {
        let env = try A.Env()
        defer { env.remove() }
        env.home.codexProcesses.run(pid: 42, home: .path(env.codexHome), files: [env.lock(A.session)])
        // 进行中会话（work 档案）：一次用量，之后一次只带 rate_limits
        try env.home.write(CodexRollout.path(A.session), CodexRollout.file([
            CodexRollout.meta(id: A.session, at: A.iso(A.start)),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: A.iso(A.start)),
            env.tokenCount(1),
            CodexRollout.tokenCount(at: A.iso(A.at(2)), last: nil,
                                    primary: .init(used: 40, minutes: 300, resetsAt: 1_793_800_000)),
        ]))
        // 找不到写入者的会话：额度不归任何账号
        try env.home.write(CodexRollout.path(A.other), CodexRollout.file([
            CodexRollout.meta(id: A.other, at: A.iso(A.start)),
            CodexRollout.tokenCount(at: A.iso(A.at(2)), last: nil,
                                    primary: .init(used: 30, minutes: 300, resetsAt: 1_793_800_000)),
        ]))

        let now = Box(A.at(5)), quotas = Box<[UsageAccount: LiveQuota]>([:])
        let updates = ProfileWatcherChecks.Counter()
        let recorder = makeRecorder(env, now: now, quotas: quotas, updates: updates)
        recorder.start()
        defer { recorder.stop() }
        try expect(waitUntil { (try? recorder.read { try $0.messages().map(\.attribution) }) == [A.work()] },
                   "启动后 5 秒内没有读入并归属")
        try expect(updates.count > 0, "账本变化后应通知")
        try expect(waitUntil { quotas.value[UsageAccount(id: A.workAccount)] != nil }, "实时额度没有交给回调")
        try expectEqual(quotas.value[UsageAccount(id: A.workAccount)]?.fiveHour?.utilization, 40)
        try expectEqual(Array(quotas.value.keys), [UsageAccount(id: A.workAccount)], "找不到写入者的会话不更新额度")

        try env.appendEvents(A.session, [3])
        try expect(waitUntil { (try? recorder.read { try $0.messages().map(\.attribution) }) == [A.work(), A.work()] },
                   "追加的事件 5 秒内没有读入并归属")
    }

    static func resumesFromStoredCursors() throws {
        let env = try A.Env()
        defer { env.remove() }
        try env.rollout(A.session, events: [1, 2])
        let now = Box(A.at(5))
        do {
            let recorder = makeRecorder(env, now: now)
            recorder.start()
            defer { recorder.stop() }
            try expect(waitUntil { (try? recorder.read { try $0.messages().count }) == 2 }, "启动后 5 秒内没有读入")
        }
        let stored = try TokenLedger(at: TokenLedger.defaultURL(environment: env.home.environment)).chatgptCursors()
        try expectEqual(stored.keys.sorted(), [env.home.url.path + "/" + CodexRollout.path(A.session)].map {
            FSEventsSupport.realPath(URL(fileURLWithPath: $0)).path
        }, "读取位置记在账本里")

        let recorder = makeRecorder(env, now: now)
        recorder.start()
        defer { recorder.stop() }
        try env.appendEvents(A.session, [3])
        try expect(waitUntil { (try? recorder.read { try $0.messages().count }) == 3 }, "重启后追加的事件没有读入")
        try expectEqual(try recorder.read { try $0.messages().map(\.tokens.input) }, [10, 10, 10])
    }

    static func listsProcessesOncePerScan() throws {
        let env = try A.Env()
        defer { env.remove() }
        let process = env.home.codexProcesses.run(pid: 42, home: .path(env.codexHome), files: [env.lock(A.session)])
        // 新会话：一次带 rate_limits 的用量（既要归属，又有实时额度）
        try env.home.write(CodexRollout.path(A.session), CodexRollout.file([
            CodexRollout.meta(id: A.session, at: A.iso(A.start)),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: A.iso(A.start)),
            CodexRollout.tokenCount(at: A.iso(A.at(1)), last: .init(input: 10, output: 1),
                                    primary: .init(used: 40, minutes: 300, resetsAt: 1_793_800_000)),
        ]))
        let now = Box(A.at(5)), quotas = Box<[UsageAccount: LiveQuota]>([:])
        let recorder = makeRecorder(env, now: now, quotas: quotas)
        recorder.start()
        defer { recorder.stop() }
        try expect(waitUntil { quotas.value[UsageAccount(id: A.workAccount)] != nil }, "实时额度没有交给回调")
        try expectEqual(try recorder.read { try $0.messages().map(\.attribution) }, [A.work()])
        // 等可能晚到的 FSEvents 扫描做完：它们没有待归属的会话、没有额度，不该再列进程
        Thread.sleep(forTimeInterval: 0.3)
        _ = try recorder.read { _ in }
        try expectEqual(env.home.codexProcesses.listCalls, 1, "列进程次数")
        try expectEqual(env.home.codexProcesses.openFileQueries, [process], "查打开的文件")
    }

    static func claudeSyncRetriesChatGPTAttribution() throws {
        let env = try A.Env()
        defer { env.remove() }
        // 创建者不是任何档案的账号：过了等待期记为未归属
        try env.rollout(A.session, creator: "user-x", events: [1])
        let now = Box(A.at(5))
        let recorder = makeRecorder(env, now: now)
        recorder.start()
        defer { recorder.stop() }
        try expect(waitUntil { (try? recorder.read { try $0.messages().map(\.attribution) }) == [.pending] },
                   "启动后 5 秒内没有读入")
        // 过了等待期，ChatGPT 没有新事件；Claude 的会话记录有变化
        now.value = A.at(120)
        try env.home.write(".claude/projects/p/s-1.jsonl", TranscriptFixture.file([
            TranscriptFixture.assistant(id: "m1", session: "s-1", at: A.iso(A.at(119)), output: 1),
        ]))
        try expect(waitUntil {
            (try? recorder.read { try $0.messages().filter { $0.tool == .chatgpt }.map(\.attribution) }) == [.unattributed]
        }, "Claude 的同步之后 ChatGPT 的会话仍没有记为未归属")
    }

    static func fullScanAfterFailedIngest() throws {
        let env = try A.Env()
        defer { env.remove() }
        env.home.codexProcesses.run(pid: 42, home: .path(env.codexHome), files: [env.lock(A.session)])
        try env.rollout(A.session, events: [1])
        // 另一个会话在另一个目录（另一天）里，先只有开头
        let otherPath = CodexRollout.path(A.other, day: "2026/11/05")
        try env.home.write(otherPath, CodexRollout.file([
            CodexRollout.meta(id: A.other, at: A.iso(A.start)),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: A.iso(A.start)),
        ]))
        let now = Box(A.at(5)), quotas = Box<[UsageAccount: LiveQuota]>([:])
        let recorder = makeRecorder(env, now: now, quotas: quotas)
        recorder.start()
        defer { recorder.stop() }
        try expect(waitUntil { (try? recorder.read { try $0.messages().count }) == 1 }, "启动后 5 秒内没有读入")
        Thread.sleep(forTimeInterval: 0.3)  // 等启动前写入的文件可能晚到的 FSEvents 扫描做完

        // 账本写不进去时会话写下最后一批，之后会话结束，它所在的目录不再有变化
        let ledgerPath = TokenLedger.defaultURL(environment: env.home.environment).path
        try SQLiteDatabase(path: ledgerPath).execute("DROP TABLE chatgpt_files")
        let handle = try FileHandle(forWritingTo: env.home.url.appendingPathComponent(CodexRollout.path(A.session)))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(CodexRollout.file([
            CodexRollout.tokenCount(at: A.iso(A.at(2)), last: .init(input: 10, output: 1),
                                    total: .init(input: 2010, output: 1),
                                    primary: .init(used: 20, minutes: 300, resetsAt: 1_793_800_000)),
        ]).utf8))
        try handle.close()
        try expect(waitUntil { quotas.value[UsageAccount(id: A.workAccount)] != nil }, "追加的事件 5 秒内没有扫描到")
        try expectEqual(try recorder.read { try $0.messages().count }, 1, "写入失败，没有记入")
        try SQLiteDatabase(path: ledgerPath).execute(
            "CREATE TABLE chatgpt_files (path TEXT PRIMARY KEY, cursor TEXT NOT NULL) WITHOUT ROWID")

        Thread.sleep(forTimeInterval: 0.3)  // 失败的那次扫描之后不再有这个目录的变化

        // 恢复后只有另一个目录里的会话有变化
        let other = try FileHandle(forWritingTo: env.home.url.appendingPathComponent(otherPath))
        try other.seekToEnd()
        try other.write(contentsOf: Data(CodexRollout.file([
            CodexRollout.tokenCount(at: A.iso(A.at(3)), last: .init(input: 7, output: 1)),
        ]).utf8))
        try other.close()
        try expect(waitUntil { (try? recorder.read { try $0.messages().count }) == 3 },
                   "写入失败的那一批没有读回来：\((try? recorder.read { try $0.messages().map(\.sessionID) }) ?? [])")
    }

    static func rereadsAfterFailedIngest() throws {
        let env = try A.Env()
        defer { env.remove() }
        env.home.codexProcesses.run(pid: 42, home: .path(env.codexHome), files: [env.lock(A.session)])
        try env.rollout(A.session, events: [1])
        let now = Box(A.at(5)), quotas = Box<[UsageAccount: LiveQuota]>([:])
        let recorder = makeRecorder(env, now: now, quotas: quotas)
        recorder.start()
        defer { recorder.stop() }
        try expect(waitUntil { (try? recorder.read { try $0.messages().count }) == 1 }, "启动后 5 秒内没有读入")

        func appendLimited(_ minute: Double, used: Double) throws {
            let handle = try FileHandle(forWritingTo: env.home.url.appendingPathComponent(CodexRollout.path(A.session)))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(CodexRollout.file([
                CodexRollout.tokenCount(at: A.iso(A.at(minute)), last: .init(input: 10, output: 1),
                                        total: .init(input: 10 + Int(minute * 1000), output: 1),
                                        primary: .init(used: used, minutes: 300, resetsAt: 1_793_800_000)),
            ]).utf8))
        }
        func fiveHourUsed() -> Double? { quotas.value[UsageAccount(id: A.workAccount)]?.fiveHour?.utilization }

        // 账本写不进去（模拟磁盘错误：位置表没了）；这一批照样交给了实时额度
        let ledgerPath = TokenLedger.defaultURL(environment: env.home.environment).path
        try SQLiteDatabase(path: ledgerPath).execute("DROP TABLE chatgpt_files")
        try appendLimited(2, used: 20)
        try expect(waitUntil { fiveHourUsed() == 20 }, "追加的事件 5 秒内没有扫描到")
        try expectEqual(try recorder.read { try $0.messages().count }, 1, "写入失败，没有记入")

        // 恢复后下一次扫描把失败的那一批一起读回来
        try SQLiteDatabase(path: ledgerPath).execute(
            "CREATE TABLE chatgpt_files (path TEXT PRIMARY KEY, cursor TEXT NOT NULL) WITHOUT ROWID")
        try appendLimited(3, used: 30)
        try expect(waitUntil { (try? recorder.read { try $0.messages().count }) == 3 },
                   "写入失败的那一批没有重读：\((try? recorder.read { try $0.messages().count }) ?? -1) 条")
    }

    /// 第一次启动：work 档案的进程写着会话，一次用量（第 1 分钟）、一份只带额度的事件（第 2 分钟，已用 40%）；
    /// 读入并归属后停止、进程退出。返回之后用的时钟
    static func recordWithWriterThenExit(_ env: A.Env) throws -> Box<Date> {
        let process = env.home.codexProcesses.run(pid: 42, home: .path(env.codexHome), files: [env.lock(A.session)])
        try env.home.write(CodexRollout.path(A.session), CodexRollout.file([
            CodexRollout.meta(id: A.session, at: A.iso(A.start)),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: A.iso(A.start)),
            env.tokenCount(1),
            CodexRollout.tokenCount(at: A.iso(A.at(2)), last: nil,
                                    primary: .init(used: 40, minutes: 300, resetsAt: 1_793_800_000)),
        ]))
        let now = Box(A.at(5))
        do {
            let recorder = makeRecorder(env, now: now)
            recorder.start()
            defer { recorder.stop() }
            try expect(waitUntil { (try? recorder.read { try $0.messages().map(\.attribution) }) == [A.work()] },
                       "第一次启动 5 秒内没有读入并归属")
        }
        env.home.codexProcesses.exit(process)
        return now
    }

    static func restoresQuotaAfterRestart() throws {
        let env = try A.Env()
        defer { env.remove() }
        let now = try recordWithWriterThenExit(env)
        let listed = env.home.codexProcesses.listCalls

        let quotas = Box<[UsageAccount: LiveQuota]>([:])
        let recorder = makeRecorder(env, now: now, quotas: quotas)
        recorder.start()
        defer { recorder.stop() }
        let work = UsageAccount(id: A.workAccount)
        try expect(waitUntil { quotas.value[work] != nil }, "重启后 5 秒内没有补回额度")
        try expectEqual(quotas.value[work]?.fiveHour?.utilization, 40)
        try expectEqual(quotas.value[work]?.receivedAt, A.at(2), "用事件自己的时间（旧数据照常变灰）")
        try expectEqual(quotas.value[work]?.profile, "work")
        Thread.sleep(forTimeInterval: 0.3)
        _ = try recorder.read { _ in }
        try expectEqual(env.home.codexProcesses.listCalls, listed, "补回额度不列进程")
    }

    static func restoreStopsAtNextUsage() throws {
        let env = try A.Env()
        defer { env.remove() }
        let now = try recordWithWriterThenExit(env)
        // App 没开时：会话在默认档案（user-d）里续用（history.jsonl 比记着的观察结果新），又用了一次，
        // 之后一份已用 70% 的额度——它属于默认档案的账号，不属于 work 的
        now.value = A.at(7)
        try env.history(nil, A.session, at: 6)
        let handle = try FileHandle(forWritingTo: env.home.url.appendingPathComponent(CodexRollout.path(A.session)))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(CodexRollout.file([
            env.tokenCount(3),
            CodexRollout.tokenCount(at: A.iso(A.at(4)), last: nil,
                                    primary: .init(used: 70, minutes: 300, resetsAt: 1_793_800_000)),
        ]).utf8))
        try handle.close()
        // 没有写入者、也没有其他证据的会话：带额度，但不归任何账号
        try env.home.write(CodexRollout.path(A.other), CodexRollout.file([
            CodexRollout.meta(id: A.other, at: A.iso(A.start), creatorUserID: nil),
            CodexRollout.tokenCount(at: A.iso(A.at(3)), last: .init(input: 5, output: 1),
                                    primary: .init(used: 90, minutes: 300, resetsAt: 1_793_800_000)),
        ]))

        let quotas = Box<[UsageAccount: LiveQuota]>([:])
        let recorder = makeRecorder(env, now: now, quotas: quotas)
        recorder.start()
        defer { recorder.stop() }
        let work = UsageAccount(id: A.workAccount)
        try expect(waitUntil { quotas.value[work] != nil }, "重启后 5 秒内没有补回额度")
        let byDefault = UsageAccount(id: A.defaultAccount)
        try expect(waitUntil { quotas.value[byDefault] != nil }, "续用的账号没有补回额度")
        try expectEqual(quotas.value[work]?.fiveHour?.utilization, 40, "下一条用量之后的额度不算 work 的")
        try expectEqual(quotas.value[byDefault]?.fiveHour?.utilization, 70)
        try expectEqual(Set(quotas.value.keys), [work, byDefault], "没归属的会话不补额度")
    }
}
