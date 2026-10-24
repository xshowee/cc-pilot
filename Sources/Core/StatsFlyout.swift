// 侧边统计面板（token-usage ticket 07，原型方案 A）显示什么。界面（Sources/App/StatsFlyoutView.swift）只按这里
// 算好的结果画，不自己判断阈值、占比或单位。从上到下：
//   顶部       账号邮箱、订阅等级（StatsFlyoutTarget）
//   圆环卡     5 小时窗口、周窗口的剩余百分比（合并了实时额度的主窗口，颜色同 UsageReading）与重置倒计时；
//              没有数字（没有数据、已重置待刷新）时显示"—"、不画弧（QuotaRing）
//   Token 用量卡、模型卡  按分段（5 小时 / 周 / 累计）显示主数字、四类比例与图例、各模型用量（TokenFigure）
//   历史卡     四类 token 堆叠柱状图，24 小时 / 30 天（HistoryBar）
// 不显示任何多账号相加的数字（spec 决策 12）：面板只显示一个账号。

import Foundation

/// 圆环卡里的一个窗口
struct QuotaRing: Equatable {
    /// 剩余百分比；没有数字时为 nil（显示"—"，不画弧）
    let remaining: Int?
    let tint: UsageTint
    /// 重置倒计时；没有数字或已经到点时为 nil
    let countdown: ResetCountdown?

    static let empty = QuotaRing(remaining: nil, tint: .plain, countdown: nil)

    static func fiveHour(_ usage: AccountUsage?, now: Date) -> QuotaRing {
        make(usage?.fiveHour(now: now), resetsAt: usage?.fiveHourWindow?.window.resetsAt, now: now)
    }

    static func sevenDay(_ usage: AccountUsage?, now: Date) -> QuotaRing {
        make(usage?.sevenDay(now: now), resetsAt: usage?.sevenDayWindow?.window.resetsAt, now: now)
    }

    private static func make(_ reading: UsageReading?, resetsAt: Date?, now: Date) -> QuotaRing {
        guard case .remaining(let percent, let tint) = reading else { return .empty }
        return QuotaRing(remaining: percent, tint: tint,
                         countdown: resetsAt.flatMap { TokenUsageDisplay.countdown(to: $0, now: now) })
    }
}

/// Token 用量卡上的分段
enum TokenUsagePeriod: CaseIterable, Hashable {
    case fiveHour, sevenDay, cumulative
}

/// 四类 token，按显示顺序
enum TokenKind: CaseIterable, Hashable {
    case input, output, cacheWrite, cacheRead

    func count(in tokens: TokenCounts) -> Int {
        switch self {
        case .input: return tokens.input
        case .output: return tokens.output
        case .cacheWrite: return tokens.cacheWrite
        case .cacheRead: return tokens.cacheRead
        }
    }
}

/// Token 用量卡和模型卡：一个分段的主数字、四类比例与图例、各模型用量
struct TokenFigure: Equatable {
    struct Part: Equatable {
        let kind: TokenKind
        /// 占合计的比例（0–1），比例条按它分段；合计为 0 时为 0
        let fraction: Double
        let value: String
        let share: String
    }

    struct ModelRow: Equatable {
        let name: String
        let value: String
        let share: String
    }

    /// 主数字（四类合计，spec 决策 5）
    let total: String
    /// 累计分段的起算点（"自 …"）；窗口分段、或账号还没有任何记录时为 nil
    let since: Date?
    let parts: [Part]
    /// 合计大的在前（TokenUsageBreakdown 已排好）
    let models: [ModelRow]

    init(_ usage: AccountTokenUsage, period: TokenUsagePeriod) {
        let breakdown: TokenUsageBreakdown
        switch period {
        case .fiveHour: breakdown = usage.fiveHour.usage
        case .sevenDay: breakdown = usage.sevenDay.usage
        case .cumulative: breakdown = usage.cumulative.usage
        }
        let sum = breakdown.tokens.total
        total = TokenUsageDisplay.compact(sum)
        since = period == .cumulative ? usage.cumulative.origin : nil
        parts = TokenKind.allCases.map { kind in
            let count = kind.count(in: breakdown.tokens)
            return Part(kind: kind, fraction: sum > 0 ? Double(count) / Double(sum) : 0,
                        value: TokenUsageDisplay.compact(count), share: TokenUsageDisplay.share(count, of: sum))
        }
        models = breakdown.byModel.map {
            ModelRow(name: $0.model, value: TokenUsageDisplay.compact($0.tokens.total),
                     share: TokenUsageDisplay.share($0.tokens.total, of: sum))
        }
    }
}

/// 历史卡的范围
enum HistoryRange: CaseIterable, Hashable {
    /// 最近 24 小时，每小时一格
    case hours
    /// 最近 30 天，每天一格
    case days
}

/// 历史卡的一根柱子：四类 token 堆叠
struct HistoryBar: Equatable {
    let start: Date
    let tokens: TokenCounts
    /// 柱高占最高一格的比例（0–1）；各格都是 0 时全为 0
    let height: Double

    static func bars(_ usage: AccountTokenUsage, range: HistoryRange) -> [HistoryBar] {
        let buckets = range == .hours ? usage.hourly : usage.daily
        let highest = buckets.map(\.tokens.total).max() ?? 0
        return buckets.map {
            HistoryBar(start: $0.start, tokens: $0.tokens,
                       height: highest > 0 ? Double($0.tokens.total) / Double(highest) : 0)
        }
    }
}

/// 统计面板显示的账号：鼠标停在哪个档案行上，就显示它所在账号的数据。同一账号的多个档案行得到同一个账号，
/// 显示同一份数据（Token 用量和额度都属于账号）。未登录的档案没有面板。
struct StatsFlyoutTarget: Equatable {
    /// 与账本里记的账号相同（UsageAccount.id，见 SessionAttribution）
    let account: UsageAccount
    let email: String?
    let tier: SubscriptionTier?

    init?(profile: Profile) {
        guard let account = profile.usageAccount else { return nil }
        self.account = account
        email = profile.account.account?.email
        tier = profile.displayTier
    }
}

/// 鼠标在档案行与统计面板之间移动时，面板显示哪一行（档案名）。
/// 停在行上立即弹出、移到另一行立即切换；离开行或面板后不马上收起，界面等一小会儿再调用 settle()，
/// 那时既不在行上也不在面板上才收起——从行移到面板要经过两个窗口之间的空隙。
/// 只把有账号的行报进来（未登录的行不算行，停在上面等同于离开）。
struct StatsFlyoutHover: Equatable {
    /// 显示哪一行；nil 表示收起
    private(set) var profile: String?
    private var overRow: String?
    private var overFlyout = false

    mutating func row(_ name: String, hovering: Bool) {
        if hovering {
            overRow = name
            profile = name
        } else if overRow == name {
            // 进入新行的通知可能先于离开旧行的到达：只清掉还记着的那一行
            overRow = nil
        }
    }

    mutating func flyout(hovering: Bool) {
        overFlyout = hovering
    }

    /// 离开后等待结束：既不在行上也不在面板上就收起
    mutating func settle() {
        if overRow == nil && !overFlyout { profile = nil }
    }

    /// 档案列表变了：rows 是此刻有账号的行。停着的行、或面板显示的那一行没了（删除、登出）时收不到离开，
    /// 这里清掉；面板显示的那一行没了就立即收起
    mutating func rowsChanged(_ rows: Set<String>) {
        if let overRow, !rows.contains(overRow) { self.overRow = nil }
        if let profile, !rows.contains(profile) { self = StatsFlyoutHover() }
    }

    /// 主面板关闭：立即收起
    mutating func dismiss() {
        self = StatsFlyoutHover()
    }
}

/// 统计面板窗口放在哪（AppKit 屏幕坐标，原点在左下）。每次显示、内容大小变化、主面板移动时都按主面板
/// 此刻的位置重算，不缓存：主面板（MenuBarExtra 的窗口）过一夜后可能离开菜单栏往下掉（未解决），
/// 弹出面板跟着它，但无论主面板在哪都压在屏幕可用区域内，不会出界。
enum StatsFlyoutPlacement {
    /// - anchor: 主面板窗口此刻的位置
    /// - visible: 主面板所在屏幕的可用区域（visibleFrame）
    static func frame(size: CGSize, beside anchor: CGRect, within visible: CGRect, gap: CGFloat) -> CGRect {
        // 优先放左边；左边放不下就放右边；两边都放不下就压在屏幕内
        var x = anchor.minX - gap - size.width
        if x < visible.minX {
            let right = anchor.maxX + gap
            x = right + size.width <= visible.maxX ? right : max(visible.minX, min(x, visible.maxX - size.width))
        }
        // 顶边与主面板对齐，再压进可用区域；比可用区域还高时保住顶部
        var y = min(anchor.maxY, visible.maxY) - size.height
        y = max(y, visible.minY)
        if size.height > visible.height { y = visible.maxY - size.height }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
