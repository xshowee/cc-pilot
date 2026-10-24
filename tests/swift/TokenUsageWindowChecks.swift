// token-usage ticket 03：窗口 Token 用量（纯计算 TokenUsageStats）。
// 窗口与额度的同名窗口对齐（spec 决策 4）。输入是一个账号已归属的明细；只计这个账号的明细由账本按账号
// 查询保证（见 TokenUsageCumulativeChecks，经 TokenLedger.accountUsage）。

import Foundation

final class TokenUsageWindowChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("知道 resets_at：5 小时窗口从 resets_at − 5h 起，周窗口从 resets_at − 7d 起", alignsWithResetsAt),
            Check("过了 resets_at：5 小时窗口从重置后本机第一条消息起，周窗口取上一个 resets_at + 7d", infersAfterReset),
            Check("过了 resets_at 已经好几段：5 小时窗口顺着消息一段段往后推", chainsFiveHourWindows),
            Check("过了 resets_at、重置后还没有消息：5 小时窗口没开始，用量为 0", fiveHourNotStarted),
            Check("从没拿到过 resets_at：滚动窗口（现在往前 5 小时 / 7 天），两个窗口各自判断", rollsWithoutResetsAt),
            Check("历史数据：最近 24 小时每小时、最近 30 天每天（本地日期），四类分开", buildsHistory),
            Check("已知的 resets_at 取自合并了实时额度的主窗口", resetsFromAccountUsage),
        ]
    }

    static let calendar = TokenLedgerRollupChecks.calendar

    static func at(_ text: String) -> Date { TranscriptLine.parseTimestamp(text)! }

    static func message(_ time: String, model: String = "claude-opus-5-5",
                        input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) -> LedgerMessage {
        LedgerMessage(messageID: UUID().uuidString, timestamp: at(time), sessionID: "s", parentSessionID: nil,
                      model: model,
                      tokens: TokenCounts(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead),
                      attribution: .attributed(profile: "work", account: "account:u-1"))
    }

    /// 明细按时间排好再传（与账本查出来的一样）
    static func stats(_ messages: [LedgerMessage], resets: KnownResets, now: String) -> AccountTokenUsage {
        TokenUsageStats.account(own: messages.sorted { $0.timestamp < $1.timestamp }, resets: resets,
                                cumulative: TokenUsageCumulative(origin: nil, usage: .empty),
                                now: at(now), calendar: calendar)
    }

    static func alignsWithResetsAt() throws {
        let messages = [
            message("2026-10-20T04:59:00Z", output: 1),          // 5 小时窗口开始前一分钟
            message("2026-10-20T05:00:00Z", input: 2, output: 20, cacheWrite: 200, cacheRead: 2000),
            message("2026-10-20T07:00:00Z", model: "claude-sonnet-4-5-20250929", output: 30),
            message("2026-10-14T09:59:00Z", output: 4),          // 周窗口开始前一分钟
            message("2026-10-14T10:00:00Z", output: 5),
        ]
        let resets = KnownResets(fiveHour: at("2026-10-20T10:00:00Z"), sevenDay: at("2026-10-21T10:00:00Z"))
        let usage = stats(messages, resets: resets, now: "2026-10-20T08:00:00Z")

        try expectEqual(usage.fiveHour.start, at("2026-10-20T05:00:00Z"))
        try expectEqual(usage.fiveHour.end, at("2026-10-20T10:00:00Z"))
        try expectEqual(usage.fiveHour.usage.tokens,
                        TokenCounts(input: 2, output: 50, cacheWrite: 200, cacheRead: 2000))
        try expectEqual(usage.fiveHour.usage.tokens.total, 2252)
        try expectEqual(usage.fiveHour.usage.byModel.map { "\($0.model) \($0.tokens.total)" },
                        ["Opus 5.5 2222", "Sonnet 4.5 30"], "按模型细分，合计大的在前")

        try expectEqual(usage.sevenDay.start, at("2026-10-14T10:00:00Z"))
        try expectEqual(usage.sevenDay.end, at("2026-10-21T10:00:00Z"))
        try expectEqual(usage.sevenDay.usage.tokens.total, 2252 + 1 + 5)
    }

    static func infersAfterReset() throws {
        let messages = [
            message("2026-10-20T09:00:00Z", output: 1),           // 上一个 5 小时窗口里
            message("2026-10-20T12:00:00Z", output: 2),           // 重置后本账号第一条
            message("2026-10-20T16:30:00Z", output: 3),
            message("2026-10-21T09:00:00Z", output: 4),           // 上一个周窗口里
            message("2026-10-21T10:00:00Z", output: 5),
        ]
        let resets = KnownResets(fiveHour: at("2026-10-20T10:00:00Z"), sevenDay: at("2026-10-21T10:00:00Z"))
        let usage = stats(messages, resets: resets, now: "2026-10-20T16:50:00Z")

        try expectEqual(usage.fiveHour.start, at("2026-10-20T12:00:00Z"))
        try expectEqual(usage.fiveHour.end, at("2026-10-20T17:00:00Z"))
        try expectEqual(usage.fiveHour.usage.tokens.output, 5)

        let later = stats(messages, resets: resets, now: "2026-10-22T08:00:00Z")
        try expectEqual(later.sevenDay.start, at("2026-10-21T10:00:00Z"))
        try expectEqual(later.sevenDay.end, at("2026-10-28T10:00:00Z"))
        try expectEqual(later.sevenDay.usage.tokens.output, 5)
        // 过了两周
        let muchLater = stats(messages, resets: resets, now: "2026-11-01T08:00:00Z")
        try expectEqual(muchLater.sevenDay.start, at("2026-10-28T10:00:00Z"))
        try expectEqual(muchLater.sevenDay.usage.tokens.output, 0)
    }

    static func chainsFiveHourWindows() throws {
        let messages = [
            message("2026-10-20T11:00:00Z", output: 1),   // 第一段 11:00–16:00
            message("2026-10-20T15:59:00Z", output: 2),
            message("2026-10-20T16:30:00Z", output: 4),   // 第二段 16:30–21:30
            message("2026-10-20T21:00:00Z", output: 8),
            message("2026-10-20T22:00:00Z", output: 16),  // 第三段 22:00–03:00
        ]
        let resets = KnownResets(fiveHour: at("2026-10-20T10:00:00Z"), sevenDay: nil)
        let second = stats(messages, resets: resets, now: "2026-10-20T21:10:00Z")
        try expectEqual(second.fiveHour.start, at("2026-10-20T16:30:00Z"))
        try expectEqual(second.fiveHour.usage.tokens.output, 12)
        let third = stats(messages, resets: resets, now: "2026-10-20T23:00:00Z")
        try expectEqual(third.fiveHour.start, at("2026-10-20T22:00:00Z"))
        try expectEqual(third.fiveHour.end, at("2026-10-21T03:00:00Z"))
        try expectEqual(third.fiveHour.usage.tokens.output, 16)
        // 第三段也过了、之后没有消息
        let idle = stats(messages, resets: resets, now: "2026-10-21T04:00:00Z")
        try expectEqual(idle.fiveHour, TokenUsageWindow(start: nil, end: nil, usage: .empty))
    }

    static func fiveHourNotStarted() throws {
        let messages = [message("2026-10-20T09:00:00Z", output: 1)]
        let resets = KnownResets(fiveHour: at("2026-10-20T10:00:00Z"), sevenDay: nil)
        let usage = stats(messages, resets: resets, now: "2026-10-20T10:30:00Z")
        try expectEqual(usage.fiveHour, TokenUsageWindow(start: nil, end: nil, usage: .empty))
    }

    static func rollsWithoutResetsAt() throws {
        let messages = [
            message("2026-10-20T02:59:00Z", output: 1),
            message("2026-10-20T03:00:00Z", output: 2),
            message("2026-10-13T07:59:00Z", output: 4),
            message("2026-10-13T08:00:00Z", output: 8),
        ]
        let usage = stats(messages, resets: KnownResets(), now: "2026-10-20T08:00:00Z")
        try expectEqual(usage.fiveHour.start, at("2026-10-20T03:00:00Z"))
        try expectEqual(usage.fiveHour.end, at("2026-10-20T08:00:00Z"))
        try expectEqual(usage.fiveHour.usage.tokens.output, 2)
        try expectEqual(usage.sevenDay.start, at("2026-10-13T08:00:00Z"))
        try expectEqual(usage.sevenDay.end, at("2026-10-20T08:00:00Z"))
        try expectEqual(usage.sevenDay.usage.tokens.output, 11)

        // 两个窗口各管各的：只知道周窗口的 resets_at 时，5 小时窗口仍是滚动的
        let mixed = stats(messages, resets: KnownResets(fiveHour: nil, sevenDay: at("2026-10-21T00:00:00Z")),
                          now: "2026-10-20T08:00:00Z")
        try expectEqual(mixed.fiveHour.start, at("2026-10-20T03:00:00Z"))
        try expectEqual(mixed.sevenDay.start, at("2026-10-14T00:00:00Z"))
        try expectEqual(mixed.sevenDay.usage.tokens.output, 3)
    }

    static func buildsHistory() throws {
        // 现在是本地（东八区）10 月 20 日 12:30
        let now = "2026-10-20T04:30:00Z"
        let messages = [
            message("2026-10-19T04:59:00Z", output: 1),                    // 24 小时之前那个钟头
            message("2026-10-19T05:00:00Z", input: 1, output: 2, cacheWrite: 3, cacheRead: 4),  // 第一个钟头
            message("2026-10-19T15:59:00Z", output: 8),                    // 本地 10 月 19 日 23:59
            message("2026-10-20T04:00:00Z", output: 16),                   // 当前钟头
            message("2026-10-20T04:10:00Z", model: "claude-sonnet-4-5", output: 32),
            message("2026-09-20T15:59:00Z", output: 64),                   // 30 天之前（本地 9 月 20 日）
            message("2026-09-20T16:00:00Z", output: 128),                  // 第一天（本地 9 月 21 日 0 点）
        ]
        let usage = stats(messages, resets: KnownResets(), now: now)

        try expectEqual(usage.hourly.count, 24)
        try expectEqual(usage.hourly.first?.start, at("2026-10-19T05:00:00Z"))
        try expectEqual(usage.hourly.first?.tokens, TokenCounts(input: 1, output: 2, cacheWrite: 3, cacheRead: 4))
        try expectEqual(usage.hourly.last?.start, at("2026-10-20T04:00:00Z"))
        try expectEqual(usage.hourly.last?.tokens.output, 48)
        try expectEqual(usage.hourly.map(\.tokens.total).reduce(0, +), 10 + 8 + 48)

        try expectEqual(usage.daily.count, 30)
        try expectEqual(usage.daily.first?.start, at("2026-09-20T16:00:00Z"))
        try expectEqual(usage.daily.first?.tokens.output, 128)
        try expectEqual(usage.daily[28].start, at("2026-10-18T16:00:00Z"))
        try expectEqual(usage.daily[28].tokens.output, 1 + 2 + 8)
        try expectEqual(usage.daily.last?.start, at("2026-10-19T16:00:00Z"))
        try expectEqual(usage.daily.last?.tokens.output, 48)
        try expectEqual(usage.daily.map(\.tokens.total).reduce(0, +), 128 + 1 + 10 + 8 + 48)
    }

    static func resetsFromAccountUsage() throws {
        let snapshot = UsageSnapshot(fiveHour: UsageWindow(utilization: 10, resetsAt: at("2026-10-20T10:00:00Z")),
                                     sevenDay: UsageWindow(utilization: 20, resetsAt: nil),
                                     fetchedAt: at("2026-10-20T08:00:00Z"))
        var usage = AccountUsage(snapshot: snapshot)
        try expectEqual(KnownResets(usage: usage), KnownResets(fiveHour: at("2026-10-20T10:00:00Z"), sevenDay: nil))
        usage.merge(live: LiveQuota(profile: "default", receivedAt: at("2026-10-20T11:00:00Z"),
                                    fiveHour: UsageWindow(utilization: 1, resetsAt: at("2026-10-20T15:00:00Z")),
                                    sevenDay: nil))
        try expectEqual(KnownResets(usage: usage), KnownResets(fiveHour: at("2026-10-20T15:00:00Z"), sevenDay: nil))
        try expectEqual(KnownResets(usage: nil), KnownResets())
    }
}
