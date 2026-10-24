// 一个账号的窗口 Token 用量和历史数据（token-usage ticket 03），从账本的明细和按天汇总算出。纯计算，不读文件。
//
// 窗口与额度的同名窗口对齐（spec 决策 4），输入是这个账号已知的 resets_at（KnownResets）：
//   5 小时窗口  resets_at 还没到：从 resets_at − 5h 起。
//               已经过了、还没有新值：以重置后这个账号本机第一条消息为起点、往后 5 小时；
//               这一段也过了，就以之后的第一条消息为起点，依此类推。重置后还没有消息时窗口没有开始，用量为 0。
//   周窗口      resets_at 还没到：从 resets_at − 7d 起；已经过了：取 resets_at + 7d（必要时再加，直到晚于现在）。
//   从没拿到过  滚动窗口：现在往前 5 小时 / 7 天。
// 只计这个账号已归属的明细；待归属、未归属的不计（spec 决策 12）。
// 历史数据：最近 24 小时每小时、最近 30 天每天（本地日期），四类 token 分开。
// 累计 Token 用量要按起算点查全部记录，由账本算好传进来（TokenLedger.cumulativeUsage）。
// 界面通过 TokenUsageRecorder.accountUsage 取得结果，不直接调用这里。

import Foundation

/// 一个账号已知的额度重置时间；没拿到过时为 nil。
/// 取刷新数据和实时额度里 resets_at 更晚的那份（合并规则见 spec 决策 9，由调用方决定）
struct KnownResets: Equatable, Sendable {
    var fiveHour: Date?
    var sevenDay: Date?
}

extension KnownResets {
    /// 取自合并了刷新结果和实时额度的两个主窗口（合并时 resets_at 更晚的优先）
    init(usage: AccountUsage?) {
        self.init(fiveHour: usage?.fiveHourWindow?.window.resetsAt, sevenDay: usage?.sevenDayWindow?.window.resetsAt)
    }
}

/// 某个模型（按显示名合并，见 ModelDisplayName）的用量
struct ModelTokenUsage: Equatable, Sendable {
    let model: String
    let tokens: TokenCounts
}

/// 一段时间的用量：四类 token（合计见 TokenCounts.total）和按模型的细分（合计大的在前）
struct TokenUsageBreakdown: Equatable, Sendable {
    let tokens: TokenCounts
    let byModel: [ModelTokenUsage]

    static let empty = TokenUsageBreakdown(tokens: .zero, byModel: [])

    /// 按模型显示名合并若干条（原始模型 ID，用量）
    init(_ entries: [(model: String, tokens: TokenCounts)]) {
        var byName: [String: TokenCounts] = [:]
        for entry in entries { byName[ModelDisplayName.name(for: entry.model), default: .zero] += entry.tokens }
        tokens = byName.values.reduce(.zero, +)
        byModel = byName.map { ModelTokenUsage(model: $0.key, tokens: $0.value) }
            .sorted { ($0.tokens.total, $1.model) > ($1.tokens.total, $0.model) }
    }

    init(tokens: TokenCounts, byModel: [ModelTokenUsage]) {
        self.tokens = tokens
        self.byModel = byModel
    }
}

/// 一个窗口：起止和其中的用量
struct TokenUsageWindow: Equatable, Sendable {
    /// 窗口起点；nil 表示重置后本机还没有消息，窗口还没开始（用量为 0）
    let start: Date?
    /// 窗口按规则结束的时刻（即重置时间）；滚动窗口是现在；窗口没开始时为 nil
    let end: Date?
    let usage: TokenUsageBreakdown
}

/// 累计 Token 用量：起算点到现在
struct TokenUsageCumulative: Equatable, Sendable {
    /// 起算点；账号在账本里没有任何记录、也没清空过时为 nil
    let origin: Date?
    let usage: TokenUsageBreakdown
}

/// 一个账号的 Token 用量，供统计面板显示
struct AccountTokenUsage: Equatable, Sendable {
    let fiveHour: TokenUsageWindow
    let sevenDay: TokenUsageWindow
    let cumulative: TokenUsageCumulative
    /// 最近 24 小时，每小时一格（按钟点对齐，最后一格是当前这个钟头），从早到晚
    let hourly: [TokenUsageBucket]
    /// 最近 30 天，每天一格（本地日期，最后一格是今天），从早到晚
    let daily: [TokenUsageBucket]
}

/// 历史数据的一格
struct TokenUsageBucket: Equatable, Sendable {
    let start: Date
    let tokens: TokenCounts
}

enum TokenUsageStats {
    static let fiveHours: TimeInterval = 5 * 3600
    static let sevenDays: TimeInterval = 7 * 86400

    /// - messages: 账本明细（可以含别的账号，这里只取 account 的）
    /// - daily: 按天汇总（同上）
    /// - cumulative: 累计 Token 用量（由账本按起算点算出）
    static func account(_ account: String, messages: [LedgerMessage], daily: [LedgerDailyUsage],
                        resets: KnownResets, cumulative: TokenUsageCumulative,
                        now: Date, calendar: Calendar) -> AccountTokenUsage {
        let own = messages.filter { $0.attribution.account == account }.sorted { $0.timestamp < $1.timestamp }
        func window(_ span: DateInterval?) -> TokenUsageWindow {
            guard let span else { return TokenUsageWindow(start: nil, end: nil, usage: .empty) }
            let inside = own.filter { $0.timestamp >= span.start && $0.timestamp < span.end }
            return TokenUsageWindow(start: span.start, end: span.end,
                                    usage: TokenUsageBreakdown(inside.map { ($0.model, $0.tokens) }))
        }
        return AccountTokenUsage(
            fiveHour: window(fiveHourWindow(resetsAt: resets.fiveHour, activity: own.map(\.timestamp), now: now)),
            sevenDay: window(sevenDayWindow(resetsAt: resets.sevenDay, now: now)),
            cumulative: cumulative,
            hourly: buckets(.hour, count: historyHours, own: own, daily: [], now: now, calendar: calendar),
            daily: buckets(.day, count: historyDays, own: own, daily: daily.filter { $0.account == account },
                           now: now, calendar: calendar))
    }

    static let historyHours = 24, historyDays = 30

    /// 截至现在的 count 格（unit 是 .hour 或 .day，按 calendar 对齐）；按天汇总按它那天的 0 点落格
    private static func buckets(_ unit: Calendar.Component, count: Int, own: [LedgerMessage],
                                daily: [LedgerDailyUsage], now: Date, calendar: Calendar) -> [TokenUsageBucket] {
        guard let current = calendar.dateInterval(of: unit, for: now) else { return [] }
        let starts = (0..<count).compactMap { calendar.date(byAdding: unit, value: $0 - count + 1, to: current.start) }
        var totals = [TokenCounts](repeating: .zero, count: starts.count)
        func add(_ tokens: TokenCounts, at time: Date) {
            guard time < current.end, let index = starts.lastIndex(where: { $0 <= time }) else { return }
            totals[index] += tokens
        }
        for message in own { add(message.tokens, at: message.timestamp) }
        for row in daily { add(row.tokens, at: row.dayStart) }
        return zip(starts, totals).map { TokenUsageBucket(start: $0, tokens: $1) }
    }

    /// 5 小时窗口；重置后还没有消息时为 nil。activity 是这个账号的消息时间，按时间排列
    static func fiveHourWindow(resetsAt: Date?, activity: [Date], now: Date) -> DateInterval? {
        guard let resetsAt else { return DateInterval(start: now - fiveHours, end: now) }
        if now < resetsAt { return DateInterval(start: resetsAt - fiveHours, end: resetsAt) }
        var boundary = resetsAt
        while true {
            guard let first = activity.first(where: { $0 >= boundary }), first <= now else { return nil }
            let end = first + fiveHours
            if now < end { return DateInterval(start: first, end: end) }
            boundary = end
        }
    }

    /// 周窗口：过了 resets_at 就按 7 天往后推，直到晚于现在
    static func sevenDayWindow(resetsAt: Date?, now: Date) -> DateInterval {
        guard var end = resetsAt else { return DateInterval(start: now - sevenDays, end: now) }
        if now >= end { end += (now.timeIntervalSince(end) / sevenDays).rounded(.down) * sevenDays + sevenDays }
        return DateInterval(start: end - sevenDays, end: end)
    }
}

extension LedgerAttribution {
    /// 已归属时的账号；待归属、未归属时为 nil
    var account: String? {
        if case .attributed(_, let account) = self { return account }
        return nil
    }
}
