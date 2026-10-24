// token-usage ticket 01：启动时回填现有会话记录，之后监听 projects/ 的变化（FSEvents）增量读入。
// 用真实文件系统事件，每一步最多等 5 秒。

import Foundation

final class TokenUsageRecorderChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("启动时回填现有会话记录；之后追加的消息自动读入", backfillsThenFollowsChanges),
            Check("projects/ 启动时还不存在，之后创建也能读入", picksUpProjectsCreatedLater),
            Check("读入之后、汇总之前先调用归属钩子；汇总只合并已归属的明细", runsAttributionBeforeRollup),
        ]
    }

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    static func makeRecorder(_ env: LedgerEnv, now: Date = Date(),
                             attribute: @escaping (TokenLedger) throws -> Void = { _ in },
                             onUpdate: @escaping () -> Void) -> TokenUsageRecorder {
        TokenUsageRecorder(environment: env.home.environment, ledgerURL: env.ledgerURL, latency: 0.05,
                           calendar: calendar, now: { now }, attribute: attribute, onUpdate: onUpdate)
    }

    static func backfillsThenFollowsChanges() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        let stamp = "2026-10-20T01:00:00Z"
        try env.transcript("p/s-1.jsonl", [TranscriptFixture.assistant(id: "m1", session: "s-1", at: stamp, output: 1)])
        let updates = ProfileWatcherChecks.Counter()
        let recorder = makeRecorder(env) { updates.increment() }
        recorder.start()
        defer { recorder.stop() }
        try expect(updates.wait(beyond: 0), "启动后 5 秒内没有回填")
        try expectEqual(try recorder.read { try $0.messages().compactMap(\.messageID) }, ["m1"])

        updates.settle()
        let before = updates.count
        try env.append("p/s-1.jsonl", [TranscriptFixture.assistant(id: "m2", session: "s-1", at: stamp, output: 2)])
        try env.transcript("p/s-1/subagents/agent-a.jsonl", [
            TranscriptFixture.assistant(id: "m3", session: "agent-a", at: stamp, output: 3),
        ])
        try expect(waitFor(3, recorder), "追加的消息 5 秒内没有读入")
        try expect(updates.count > before, "读入新消息后应通知")
    }

    static func picksUpProjectsCreatedLater() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        let recorder = makeRecorder(env) {}
        recorder.start()
        defer { recorder.stop() }
        try recorder.read { _ in }  // 等启动时的回填做完
        try env.transcript("p/s-1.jsonl", [
            TranscriptFixture.assistant(id: "m1", session: "s-1", at: "2026-10-20T01:00:00Z", output: 1),
        ])
        try expect(waitFor(1, recorder), "新建的 projects/ 里的会话记录 5 秒内没有读入")
    }

    static func runsAttributionBeforeRollup() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try env.transcript("p/s-a.jsonl", [
            TranscriptFixture.assistant(id: "a1", session: "s-a", at: "2026-09-01T02:00:00Z", output: 10),
        ])
        try env.transcript("p/s-b.jsonl", [
            TranscriptFixture.assistant(id: "b1", session: "s-b", at: "2026-09-01T02:00:00Z", output: 1),
        ])
        let now = TranscriptLine.parseTimestamp("2026-10-20T04:00:00Z")!
        let recorder = makeRecorder(env, now: now, attribute: { ledger in
            try ledger.attribute(sessionID: "s-a", as: .attributed(profile: "work", account: "account:u-1"))
        }) {}
        recorder.start()
        defer { recorder.stop() }
        try expectEqual(try recorder.read { try $0.messages().compactMap(\.messageID) }, ["b1"])
        try expectEqual(try recorder.read { try $0.dailyUsage().map(\.tokens.output) }, [10])
    }

    /// 等到账本里有 count 条明细
    static func waitFor(_ count: Int, _ recorder: TokenUsageRecorder, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? recorder.read { try $0.messages().count }) == count { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}
