// 一个额度窗口此刻该怎么显示（spec "刷新与界面"、ticket 12）。列表、菜单栏、按模型细分的周窗口
// （ticket 13）都用它，界面只按结果选文字和颜色，不自己判断过期、重置或阈值。
// 颜色阈值是内置的（token-usage 决定 10），所有显示剩余额度的地方都用 UsageTint(remainingPercent:)。
//
// 规则（按顺序）：
//   没有窗口（utilization 为 null、缺失等）    → unavailable，显示"—"
//   已经过了 resets_at（恰好等于也算）         → resetPendingRefresh，"已重置，待刷新"，不再显示旧数字
//   数据获取时间超过 30 分钟                   → 剩余百分比，变灰（优先于阈值颜色）
//   其余                                       → 剩余百分比，剩余 ≤20 红、≤50 黄、其余绿
//                                                （与 ~/.claude/statusline.sh 的已用 ≥80 / ≥50 一致）

import Foundation

/// 数字的颜色
enum UsageTint: Equatable {
    /// 不着色（没有百分比可判断，如超额付费、菜单栏没有数字时）
    case plain
    /// 数据已过时：变灰
    case stale
    /// 按剩余百分比的内置阈值（见 init(remainingPercent:)）
    case green, yellow, red

    /// 剩余百分比对应的颜色：≤20 红、≤50 黄、其余绿。
    /// 传入显示出来的整数（UsageWindow.remainingPercent），颜色与数字一致。
    init(remainingPercent: Int) {
        switch remainingPercent {
        case ...20: self = .red
        case ...50: self = .yellow
        default: self = .green
        }
    }
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
            self = .remaining(window.remainingPercent, tint: UsageTint(remainingPercent: window.remainingPercent))
        }
    }

    /// 数据是否已过时（获取时间距今超过 30 分钟）
    static func isStale(fetchedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(fetchedAt) > staleAfter
    }
}
