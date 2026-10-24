// token-usage ticket 03：累计 Token 用量、起算点与清空（经账本 TokenLedger）。
// 起算点默认是账号在账本里最早一条记录的时间；清空把起算点移到当前时刻，持久保存，只影响累计、不影响窗口。

import Foundation

final class TokenUsageCumulativeChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("累计从账号最早一条记录起，含按天汇总；按模型细分；窗口和历史也经账本算出", cumulativeFromEarliest),
            Check("清空后累计归零、起算点是清空时刻，窗口用量不变；之后的新消息照常累计", clearResetsCumulativeOnly),
            Check("起算点持久保存：重新打开账本仍然有效", originSurvivesReopen),
            Check("清空全部账号：所有账号连同未归属一起移动起算点，之后才归属的旧消息也不算", clearAllMovesEveryone),
            Check("起算点落在已汇总的那天中间：那天的汇总整天不计", originInsideRolledUpDay),
            Check("经 TokenUsageRecorder：按它的时钟和日历查询、清空，清空后通知界面", recorderClearsAndNotifies),
        ]
    }

    static let calendar = TokenLedgerRollupChecks.calendar
    static func at(_ text: String) -> Date { TranscriptLine.parseTimestamp(text)! }
    static let now = at("2026-10-20T04:00:00Z")
    static let resets = KnownResets(fiveHour: at("2026-10-20T06:00:00Z"), sevenDay: at("2026-10-22T00:00:00Z"))

    /// 两条一个月前（会被汇总）、三条最近的 u-1 消息，一条 u-2 的
    static func seed(_ env: LedgerEnv) throws {
        try env.transcript("p/s-old.jsonl", [
            TranscriptFixture.assistant(id: "o1", session: "s-old", at: "2026-09-01T02:00:00Z", output: 1),
            TranscriptFixture.assistant(id: "o2", session: "s-old", at: "2026-09-02T02:00:00Z", output: 2),
        ])
        try env.transcript("p/s-new.jsonl", [
            TranscriptFixture.assistant(id: "n1", session: "s-new", at: "2026-10-16T00:00:00Z", output: 4),
            TranscriptFixture.assistant(id: "n2", session: "s-new", at: "2026-10-20T02:00:00Z",
                                        input: 1, output: 8, cacheWrite: 10, cacheRead: 100),
            TranscriptFixture.assistant(id: "n3", session: "s-new", model: "claude-sonnet-4-5",
                                        at: "2026-10-20T03:00:00Z", output: 16),
        ])
        try env.transcript("p/s-other.jsonl", [
            TranscriptFixture.assistant(id: "x1", session: "s-other", at: "2026-10-20T03:00:00Z", output: 999),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)
        for session in ["s-old", "s-new"] {
            try env.ledger.attribute(sessionID: session, as: .attributed(profile: "work", account: "account:u-1"))
        }
        try env.ledger.attribute(sessionID: "s-other", as: .attributed(profile: "home", account: "account:u-2"))
        try env.ledger.rollUp(now: now, retentionDays: 35, calendar: calendar)
    }

    static func usage(_ ledger: TokenLedger, at time: Date = now) throws -> AccountTokenUsage {
        try ledger.accountUsage("account:u-1", resets: resets, now: time, calendar: calendar)
    }

    static func cumulativeFromEarliest() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try seed(env)
        try expectEqual(try env.ledger.dailyUsage().count, 2, "前提：一个月前的两条已汇总")

        let usage = try usage(env.ledger)
        try expectEqual(usage.cumulative.origin, at("2026-08-31T16:00:00Z"), "最早一条记录是 9 月 1 日的汇总")
        try expectEqual(usage.cumulative.usage.tokens,
                        TokenCounts(input: 1, output: 1 + 2 + 4 + 8 + 16, cacheWrite: 10, cacheRead: 100))
        try expectEqual(usage.cumulative.usage.byModel.map { "\($0.model) \($0.tokens.total)" },
                        ["Opus 5.5 126", "Sonnet 4.5 16"])
        try expectEqual(usage.fiveHour.usage.tokens.output, 8 + 16)
        try expectEqual(usage.sevenDay.usage.tokens.output, 4 + 8 + 16)
        try expectEqual(usage.daily.map(\.tokens.output).reduce(0, +), 4 + 8 + 16)
        try expectEqual(usage.hourly.map(\.tokens.output).reduce(0, +), 8 + 16)

        let other = try env.ledger.accountUsage("account:u-2", resets: KnownResets(), now: now, calendar: calendar)
        try expectEqual(other.cumulative.origin, at("2026-10-20T03:00:00Z"))
        try expectEqual(other.cumulative.usage.tokens.output, 999)

        let nobody = try env.ledger.accountUsage("account:none", resets: KnownResets(), now: now, calendar: calendar)
        try expectEqual(nobody.cumulative, TokenUsageCumulative(origin: nil, usage: .empty))
    }

    static func clearResetsCumulativeOnly() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try seed(env)
        let before = try usage(env.ledger)

        try env.ledger.clearCumulative(account: "account:u-1", at: now)
        let after = try usage(env.ledger)
        try expectEqual(after.cumulative, TokenUsageCumulative(origin: now, usage: .empty))
        try expectEqual(after.fiveHour, before.fiveHour, "清空不影响 5 小时窗口")
        try expectEqual(after.sevenDay, before.sevenDay, "清空不影响周窗口")
        try expectEqual(after.daily, before.daily, "清空不影响历史数据")
        let other = try env.ledger.accountUsage("account:u-2", resets: KnownResets(), now: now, calendar: calendar)
        try expectEqual(other.cumulative.usage.tokens.output, 999, "只清空这一个账号")

        try env.append("p/s-new.jsonl", [
            TranscriptFixture.assistant(id: "n4", session: "s-new", at: "2026-10-20T04:30:00Z", output: 32),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)
        try env.ledger.attribute(sessionID: "s-new", as: .attributed(profile: "work", account: "account:u-1"))
        let later = try usage(env.ledger, at: at("2026-10-20T05:00:00Z"))
        try expectEqual(later.cumulative.origin, now)
        try expectEqual(later.cumulative.usage.tokens.output, 32)
    }

    static func originSurvivesReopen() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try seed(env)
        try env.ledger.clearCumulative(account: "account:u-1", at: now)
        let reopened = try TokenLedger(at: env.ledgerURL)
        try expectEqual(try usage(reopened).cumulative, TokenUsageCumulative(origin: now, usage: .empty))
    }

    static func clearAllMovesEveryone() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try seed(env)
        // 一个找不到归属的会话，一个还没归属的会话（都在清空之前）
        try env.transcript("p/s-lost.jsonl", [
            TranscriptFixture.assistant(id: "l1", session: "s-lost", at: "2026-10-20T03:00:00Z", output: 7),
        ])
        try env.transcript("p/s-late.jsonl", [
            TranscriptFixture.assistant(id: "p1", session: "s-late", at: "2026-10-20T03:30:00Z", output: 9),
        ])
        try env.ledger.ingest(projectsRoot: env.projects)
        try env.ledger.attribute(sessionID: "s-lost", as: .unattributed)
        try expectEqual(try env.ledger.cumulativeUsage(account: nil).usage.tokens.output, 7)
        try env.ledger.clearCumulative(account: "account:u-1", at: at("2026-10-20T00:00:00Z"))

        try env.ledger.clearAllCumulative(at: now)
        for account in ["account:u-1", "account:u-2"] {
            let usage = try env.ledger.accountUsage(account, resets: KnownResets(), now: now, calendar: calendar)
            try expectEqual(usage.cumulative, TokenUsageCumulative(origin: now, usage: .empty), account)
        }
        try expectEqual(try env.ledger.cumulativeUsage(account: nil),
                        TokenUsageCumulative(origin: now, usage: .empty), "未归属也一起清空")

        // 清空之前的消息之后才归属到一个新账号：不算进累计（窗口照算）
        try env.ledger.attribute(sessionID: "s-late", as: .attributed(profile: "new", account: "account:u-3"))
        let newcomer = try env.ledger.accountUsage("account:u-3", resets: KnownResets(), now: now, calendar: calendar)
        try expectEqual(newcomer.cumulative, TokenUsageCumulative(origin: now, usage: .empty))
        try expectEqual(newcomer.fiveHour.usage.tokens.output, 9)

        // 之后单独清空某个账号，取较晚的那个起算点
        let later = at("2026-10-20T05:00:00Z")
        try env.ledger.clearCumulative(account: "account:u-2", at: later)
        let u2 = try env.ledger.accountUsage("account:u-2", resets: KnownResets(), now: later, calendar: calendar)
        try expectEqual(u2.cumulative.origin, later)
        try expectEqual(try usage(env.ledger, at: later).cumulative.origin, now)
    }

    static func originInsideRolledUpDay() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try seed(env)
        // 9 月 1 日（本地）中午清空过：那天的汇总分不开，整天不计；9 月 2 日起照常
        try env.ledger.clearCumulative(account: "account:u-1", at: at("2026-09-01T04:00:00Z"))
        let usage = try usage(env.ledger)
        try expectEqual(usage.cumulative.origin, at("2026-09-01T04:00:00Z"))
        try expectEqual(usage.cumulative.usage.tokens.output, 2 + 4 + 8 + 16)
    }

    static func recorderClearsAndNotifies() throws {
        let env = try LedgerEnv()
        defer { env.remove() }
        try seed(env)
        let updates = ProfileWatcherChecks.Counter()
        let recorder = TokenUsageRecorderChecks.makeRecorder(env, now: now) { updates.increment() }
        try expectEqual(try recorder.accountUsage("account:u-1", resets: resets), try usage(env.ledger))

        try recorder.clearCumulative(account: "account:u-1")
        try expectEqual(try recorder.accountUsage("account:u-1", resets: resets).cumulative,
                        TokenUsageCumulative(origin: now, usage: .empty))
        try expectEqual(updates.count, 1)
        try recorder.clearAllCumulative()
        try expectEqual(try recorder.accountUsage("account:u-2", resets: KnownResets()).cumulative,
                        TokenUsageCumulative(origin: now, usage: .empty))
        try expectEqual(updates.count, 2)
    }
}
