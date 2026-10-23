// 一个额度窗口此刻该怎么显示（spec "刷新与界面"、ticket 12）。列表、菜单栏、按模型细分的周窗口
// （ticket 13）都用它，界面只按结果选文字和颜色，不自己判断过期、重置或阈值。
//
// 规则（按顺序）：
//   没有窗口（utilization 为 null、缺失等）    → unavailable，显示"—"
//   已经过了 resets_at（恰好等于也算）         → resetPendingRefresh，"已重置，待刷新"，不再显示旧数字
//   数据获取时间超过 30 分钟                   → 剩余百分比，变灰（优先于 severity 的颜色）
//   其余                                       → 剩余百分比，颜色取自 severity；没有 severity 时不着色

import Foundation

/// 数字的颜色
enum UsageTint: Equatable {
    /// 不着色（服务端没给出严重程度）
    case plain
    /// 数据已过时：变灰
    case stale
    /// 服务端给出的严重程度
    case severity(UsageSeverity)
}

enum UsageReading: Equatable {
    /// 没有数字可显示："—"
    case unavailable
    /// 已经过了重置时间：显示"已重置，待刷新"
    case resetPendingRefresh
    /// 剩余百分比（0–100）及其颜色
    case remaining(Int, tint: UsageTint)

    /// 获取时间距今超过这么久，数字变灰
    static let staleAfter: TimeInterval = 30 * 60

    /// fetchedAt 是这个窗口所在数据的获取时间
    init(_ window: UsageWindow?, fetchedAt: Date, now: Date) {
        guard let window else { self = .unavailable; return }
        if let resetsAt = window.resetsAt, resetsAt <= now {
            self = .resetPendingRefresh
        } else if Self.isStale(fetchedAt: fetchedAt, now: now) {
            self = .remaining(window.remainingPercent, tint: .stale)
        } else {
            self = .remaining(window.remainingPercent, tint: window.severity.map(UsageTint.severity) ?? .plain)
        }
    }

    /// 数据是否已过时（获取时间距今超过 30 分钟）
    static func isStale(fetchedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) > staleAfter
    }
}
