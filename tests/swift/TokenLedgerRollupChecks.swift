// token-usage ticket 01：归属接口（给 ticket 02 用）和超过保留期的明细合并成"每账号、每模型、每天"汇总。
// 汇总只合并已经确定归属（含确定未归属）的明细；还在等归属的明细不汇总。

import Foundation

final class TokenLedgerRollupChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("待归属的会话按归属用的会话 ID 列出；归属只改待归属的明细", attributesPendingSessions),
            Check("超过保留期、已归属的明细按账号、模型、本地日期合并成汇总", rollsUpAttributedOldMessages),
            Check("还没归属的明细超过保留期也不汇总，归属后下次再汇总并累加", keepsPendingUntilAttributed),
            Check("已汇总的消息又出现在 resume 出来的会话记录里，不再记一次", rolledMessagesStayCounted),
        ]
    }

    /// 东八区：UTC 17:00 已经是本地第二天
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    static let now = TranscriptLine.parseTimestamp("2026-10-20T04:00:00Z")!  // 本地 10-20 12:00

    static func attributesPendingSessions() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        let t = "2026-10-20T01:00:00Z"
        try env.transcript("p/s-1.jsonl", [TranscriptFixture.assistant(id: "m1", session: "s-1", at: t, output: 1)])
        try env.transcript("p/s-1/subagents/agent-a.jsonl", [
            TranscriptFixture.assistant(id: "m2", session: "agent-a", at: t, output: 2),
        ])
        try env.transcript("p/s-2.jsonl", [TranscriptFixture.assistant(id: "m3", session: "s-2", at: t, output: 3)])
        try env.ledger.ingest(projectsRoot: env.projects)
        try expectEqual(try env.ledger.pendingSessionIDs(), ["s-1", "s-2"])

        try env.ledger.attribute(sessionID: "s-1", as: .attributed(profile: "work", account: "account:u-1"))
        try env.ledger.attribute(sessionID: "s-2", as: .unattributed)
        try expectEqual(try env.ledger.pendingSessionIDs(), [])
        let byID = Dictionary(uniqueKeysWithValues: try env.ledger.messages().map { ($0.messageID!, $0.attribution) })
        try expectEqual(byID["m1"], .attributed(profile: "work", account: "account:u-1"))
        try expectEqual(byID["m2"], .attributed(profile: "work", account: "account:u-1"), "子代理随父会话归属")
        try expectEqual(byID["m3"], .unattributed)

        // 档案之后换了登录：同一会话的新消息另行归属，旧记录不改
        try env.append("p/s-1.jsonl", [TranscriptFixture.assistant(id: "m4", session: "s-1", at: t, output: 4)])
        try env.ledger.ingest(projectsRoot: env.projects)
        try expectEqual(try env.ledger.pendingSessionIDs(), ["s-1"])
        try env.ledger.attribute(sessionID: "s-1", as: .attributed(profile: "work", account: "account:u-2"))
        let after = Dictionary(uniqueKeysWithValues: try env.ledger.messages().map { ($0.messageID!, $0.attribution) })
        try expectEqual(after["m1"], .attributed(profile: "work", account: "account:u-1"))
        try expectEqual(after["m4"], .attributed(profile: "work", account: "account:u-2"))
    }

    static func rollsUpAttributedOldMessages() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        // 保留 35 天：本地 9 月 15 日 00:00 之前的明细合并
        try env.transcript("p/s-old.jsonl", [
            // 本地 9 月 1 日两条同模型，合成一行
            TranscriptFixture.assistant(id: "a1", session: "s-old", at: "2026-09-01T02:00:00Z",
                                        input: 1, output: 10, cacheWrite: 100, cacheRead: 1000),
            TranscriptFixture.assistant(id: "a2", session: "s-old", at: "2026-09-01T03:00:00Z",
                                        input: 2, output: 20, cacheWrite: 200, cacheRead: 2000),
            // UTC 9 月 1 日 17:00 = 本地 9 月 2 日
            TranscriptFixture.assistant(id: "a3", session: "s-old", at: "2026-09-01T17:00:00Z", output: 5),
            // 不同版本的模型分开
            TranscriptFixture.assistant(id: "a4", session: "s-old", model: "claude-sonnet-4-5-20250929",
                                        at: "2026-09-01T04:00:00Z", output: 7),
            // UTC 9 月 14 日 16:30 = 本地 9 月 15 日 00:30，还在保留期内
            TranscriptFixture.assistant(id: "keep", session: "s-old", at: "2026-09-14T16:30:00Z", output: 9),
        ])
        try env.transcript("p/s-lost.jsonl", [
            TranscriptFixture.assistant(id: "u1", session: "s-lost", at: "2026-09-01T02:00:00Z", output: 3),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)
        try env.ledger.attribute(sessionID: "s-old", as: .attributed(profile: "work", account: "account:u-1"))
        try env.ledger.attribute(sessionID: "s-lost", as: .unattributed)

        try env.ledger.rollUp(now: now, retentionDays: 35, calendar: calendar)

        try expectEqual(try env.ledger.messages().compactMap(\.messageID), ["keep"])
        let daily = try env.ledger.dailyUsage()
        try expectEqual(daily.map { "\($0.day) \($0.account ?? "未归属") \($0.model) \($0.tokens.total)" }, [
            "2026-09-01 account:u-1 claude-opus-5-5 3333",
            "2026-09-01 account:u-1 claude-sonnet-4-5-20250929 7",
            "2026-09-01 未归属 claude-opus-5-5 3",
            "2026-09-02 account:u-1 claude-opus-5-5 5",
        ])
        try expectEqual(daily[0].tokens, TokenCounts(input: 3, output: 30, cacheWrite: 300, cacheRead: 3000))
        try expectEqual(daily[0].dayStart, TranscriptLine.parseTimestamp("2026-08-31T16:00:00Z")!)
    }

    static func keepsPendingUntilAttributed() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try env.transcript("p/s-a.jsonl", [
            TranscriptFixture.assistant(id: "a1", session: "s-a", at: "2026-09-01T02:00:00Z", output: 10),
        ])
        try env.transcript("p/s-b.jsonl", [
            TranscriptFixture.assistant(id: "b1", session: "s-b", at: "2026-09-01T03:00:00Z", output: 1),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)
        try env.ledger.attribute(sessionID: "s-a", as: .attributed(profile: "work", account: "account:u-1"))
        try env.ledger.rollUp(now: now, retentionDays: 35, calendar: calendar)
        try expectEqual(try env.ledger.messages().compactMap(\.messageID), ["b1"], "待归属的明细应留着")

        try env.ledger.attribute(sessionID: "s-b", as: .attributed(profile: "home", account: "account:u-1"))
        try env.ledger.rollUp(now: now, retentionDays: 35, calendar: calendar)
        try expectEqual(try env.ledger.messages().count, 0)
        let daily = try env.ledger.dailyUsage()
        try expectEqual(daily.count, 1)
        try expectEqual(daily[0].tokens.output, 11, "同一账号、模型、日期的汇总应累加")
    }

    static func rolledMessagesStayCounted() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        let old = TranscriptFixture.assistant(id: "a1", session: "s-a", at: "2026-09-01T02:00:00Z", output: 10)
        try env.transcript("p/s-a.jsonl", [old])
        try env.ledger.ingest(projectsRoot: env.projects)
        try env.ledger.attribute(sessionID: "s-a", as: .attributed(profile: "work", account: "account:u-1"))
        try env.ledger.rollUp(now: now, retentionDays: 35, calendar: calendar)

        // 一个月后 resume 这个会话：新文件开头原样带着旧消息
        try env.transcript("p/s-r.jsonl", [
            old, TranscriptFixture.assistant(id: "r1", session: "s-r", at: "2026-10-20T01:00:00Z", output: 2),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)
        try expectEqual(try env.ledger.messages().compactMap(\.messageID), ["r1"])
        try expectEqual(try env.ledger.dailyUsage().map(\.tokens.output), [10])
    }
}
