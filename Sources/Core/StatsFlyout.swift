// 侧边统计面板（token-usage ticket 07，原型方案 A）显示什么。界面（Sources/App/StatsFlyoutView.swift）只按这里
// 算好的结果画，不自己判断阈值、占比或单位。从上到下：
//   顶部       账号邮箱（StatsFlyoutTarget）、订阅等级
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

    /// 一个窗口的显示（UsageReading）对应的圆环：有剩余数字时画弧、带倒计时；已重置待刷新、没有数字时为 empty。
    /// Antigravity 的圆环按看板给的读数用它（AntigravityFlyout）
    static func make(_ reading: UsageReading?, resetsAt: Date?, now: Date) -> QuotaRing {
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

    /// 不含缓存写入的 3 类（Antigravity 等不产生 cacheWrite 的面板）
    static let withoutCacheWrite: [TokenKind] = [.input, .output, .cacheRead]

    func count(in tokens: TokenCounts) -> Int {
        switch self {
        case .input: return tokens.input
        case .output: return tokens.output
        case .cacheWrite: return tokens.cacheWrite
        case .cacheRead: return tokens.cacheRead
        }
    }
}

/// Token 用量卡和模型卡：一个分段的主数字、各类比例与图例、各模型用量
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
        let costText: String?
        let isUnpriced: Bool

        init(name: String, value: String, share: String, costText: String? = nil, isUnpriced: Bool = false) {
            self.name = name
            self.value = value
            self.share = share
            self.costText = costText
            self.isUnpriced = isUnpriced
        }
    }

    /// 显示与计入合计的 token 类别
    let kinds: [TokenKind]
    /// 主数字（所选类别的合计，spec 决策 5）
    let total: String
    /// 累计分段的起算点（"自 …"）；窗口分段、或账号还没有任何记录时为 nil
    let since: Date?
    let parts: [Part]
    /// 合计大的在前（按所选类别重新排序并过滤为 0 的模型）
    let models: [ModelRow]
    /// 按静态定价目录算出的等效 API 美元费用与缓存节省（仅 Antigravity 面板开启）
    let cost: AntigravityCostSummary?

    init(_ usage: AccountTokenUsage, period: TokenUsagePeriod,
         kinds: [TokenKind] = TokenKind.allCases, includeCost: Bool = false) {
        let breakdown: TokenUsageBreakdown
        switch period {
        case .fiveHour: breakdown = usage.fiveHour.usage
        case .sevenDay: breakdown = usage.sevenDay.usage
        case .cumulative: breakdown = usage.cumulative.usage
        }
        self.kinds = kinds
        let sum = breakdown.tokens.total(for: kinds)
        total = TokenUsageDisplay.compact(sum)
        since = period == .cumulative ? usage.cumulative.origin : nil
        parts = kinds.map { kind in
            let count = kind.count(in: breakdown.tokens)
            return Part(kind: kind, fraction: sum > 0 ? Double(count) / Double(sum) : 0,
                        value: TokenUsageDisplay.compact(count), share: TokenUsageDisplay.share(count, of: sum))
        }
        let costSummary = includeCost ? AntigravityPricing.summarize(breakdown, kinds: kinds) : nil
        cost = costSummary
        models = breakdown.byModel
            .map { (model: $0.model, total: $0.tokens.total(for: kinds)) }
            .filter { $0.total > 0 }
            .sorted { ($0.total, $1.model) > ($1.total, $0.model) }
            .map {
                let rowCost = costSummary?.byModelName[$0.model]
                return ModelRow(
                    name: $0.model,
                    value: TokenUsageDisplay.compact($0.total),
                    share: TokenUsageDisplay.share($0.total, of: sum),
                    costText: rowCost?.costText,
                    isUnpriced: rowCost?.isUnpriced ?? false)
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

/// 历史卡的一根柱子：各类 token 堆叠
struct HistoryBar: Equatable {
    let start: Date
    let tokens: TokenCounts
    /// 柱高占最高一格的比例（0–1）；各格都是 0 时全为 0
    let height: Double

    static func bars(_ usage: AccountTokenUsage, range: HistoryRange,
                     kinds: [TokenKind] = TokenKind.allCases) -> [HistoryBar] {
        let buckets = range == .hours ? usage.hourly : usage.daily
        let highest = buckets.map { $0.tokens.total(for: kinds) }.max() ?? 0
        return buckets.map {
            let bucketTotal = $0.tokens.total(for: kinds)
            return HistoryBar(start: $0.start, tokens: $0.tokens,
                              height: highest > 0 ? Double(bucketTotal) / Double(highest) : 0)
        }
    }
}

/// 历史柱状图的鼠标悬停：鼠标停在哪一格、竖线画在哪、提示框放在哪（坐标都以图的左边为 0）。
/// 按横向位置吸附到所在的那一格，空白处和很矮的柱子也能停；图外夹到两端。
enum HistoryHover {
    static func index(x: CGFloat, width: CGFloat, count: Int) -> Int? {
        guard count > 0, width > 0 else { return nil }
        return min(count - 1, max(0, Int(x / (width / CGFloat(count)))))
    }

    /// 竖线：格子正中
    static func lineX(index: Int, width: CGFloat, count: Int) -> CGFloat {
        (CGFloat(index) + 0.5) * width / CGFloat(count)
    }

    /// 提示框左边：优先放竖线右边，放不下换左边，都放不下时贴着卡片左边
    static func tooltipX(lineX: CGFloat, tooltipWidth: CGFloat, width: CGFloat, gap: CGFloat) -> CGFloat {
        if lineX + gap + tooltipWidth <= width { return lineX + gap }
        return max(0, lineX - gap - tooltipWidth)
    }
}

/// 统计面板显示的账号：鼠标停在哪个档案行上，就显示它所在账号的数据。同一账号的多个档案行得到同一个账号，
/// 显示同一份数据（Token 用量和额度都属于账号）。未登录的档案没有面板。ChatGPT 档案见 StatsFlyout+ChatGPT.swift。
struct StatsFlyoutTarget: Equatable {
    /// 与账本里记的账号相同（UsageAccount.id，见 SessionAttribution）
    let account: UsageAccount
    let email: String?

    init(account: UsageAccount, email: String?) {
        self.account = account
        self.email = email
    }

    init?(profile: Profile) {
        guard let account = profile.usageAccount else { return nil }
        self.account = account
        email = profile.account.account?.email
    }
}

/// 统计面板里的一行：工具 + 档案名。两个工具可以有同名档案（各自独立），只按档案名会串到另一个工具的行上。
/// Kimi Code 不是工具（ADR 0007），它的卡片是单独的一种行（.kimi，名称是账号名称），面板显示 Base URL 和模型列表。
/// Antigravity 也不是工具，它的卡片是另一种行（.antigravity，名称是邮箱），面板显示套餐和各组额度
/// （AntigravityFlyout，见 StatsFlyout+Antigravity.swift）。
struct StatsFlyoutRow: Hashable {
    enum Section: Hashable {
        case tool(Tool)
        case kimi
        case antigravity
    }

    let section: Section
    let name: String

    init(tool: Tool, name: String) {
        section = .tool(tool)
        self.name = name
    }

    /// Kimi Code 账号的卡片
    static func kimi(_ name: String) -> StatsFlyoutRow { StatsFlyoutRow(section: .kimi, name: name) }

    /// Antigravity 邮箱的卡片
    static func antigravity(_ email: String) -> StatsFlyoutRow { StatsFlyoutRow(section: .antigravity, name: email) }

    private init(section: Section, name: String) {
        self.section = section
        self.name = name
    }

    /// 此刻有面板的行，各段的都在里面（StatsFlyoutHover.rowsChanged 要全部的行）。
    /// 每个 Kimi Code 账号都有面板（Base URL 不用请求，还没刷新过也能看）；每个 Antigravity 邮箱（AntigravityBoard.emails，
    /// 含格式无法识别后没有快照数据的卡片）都有面板
    static func rows(claudeCode: [Profile], chatgpt: [ChatGPTProfile], kimi: [String] = [],
                     antigravity: [String] = []) -> Set<StatsFlyoutRow> {
        Set(claudeCode.filter { StatsFlyoutTarget(profile: $0) != nil }.map { StatsFlyoutRow(tool: .claudeCode, name: $0.name) }
            + chatgpt.filter { StatsFlyoutTarget(chatgpt: $0) != nil }.map { StatsFlyoutRow(tool: .chatgpt, name: $0.name) }
            + kimi.map(StatsFlyoutRow.kimi)
            + antigravity.map(StatsFlyoutRow.antigravity))
    }
}

/// 统计面板要读取的 Token 用量请求：账号与已知的额度重置时间
struct StatsFlyoutTokenRequest: Equatable, Sendable {
    let account: UsageAccount
    let resets: KnownResets

    /// 解析鼠标停着的行要读取哪份 Token 用量；Kimi Code 与未登录档案返回 nil
    static func resolve(row: StatsFlyoutRow?, claudeCode: [Profile], chatgpt: [ChatGPTProfile],
                        board: UsageBoard, antigravity: AntigravityBoard = AntigravityBoard()) -> StatsFlyoutTokenRequest? {
        guard let row else { return nil }
        let target: StatsFlyoutTarget?
        switch row.section {
        case .kimi:
            return nil
        case .antigravity:
            guard !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return StatsFlyoutTokenRequest(
                account: .antigravity(cardEmail: row.name),
                resets: antigravity.knownResets(for: row.name))
        case .tool(.claudeCode):
            target = claudeCode.first { $0.name == row.name }.flatMap(StatsFlyoutTarget.init(profile:))
        case .tool(.chatgpt):
            target = chatgpt.first { $0.name == row.name }.flatMap(StatsFlyoutTarget.init(chatgpt:))
        }
        guard let target else { return nil }
        return StatsFlyoutTokenRequest(account: target.account, resets: KnownResets(usage: board.usage(for: target.account)))
    }
}

/// 统计面板顶层容器驱动 Token 读取的生命周期状态机：
/// 只观察唯一活跃请求的变化，不依赖子视图自己的 onAppear / onDisappear，避免跨段切换时旧视图滞后触发 hide。
struct StatsFlyoutTokenLifecycle: Equatable, Sendable {
    enum Effect: Equatable, Sendable {
        case show(StatsFlyoutTokenRequest)
        case hide
    }

    private(set) var active: StatsFlyoutTokenRequest?

    mutating func update(to request: StatsFlyoutTokenRequest?) -> Effect? {
        guard request != active else { return nil }
        active = request
        return request.map(Effect.show) ?? .hide
    }

    mutating func update(row: StatsFlyoutRow?, claudeCode: [Profile], chatgpt: [ChatGPTProfile],
                         board: UsageBoard, antigravity: AntigravityBoard = AntigravityBoard()) -> Effect? {
        update(to: StatsFlyoutTokenRequest.resolve(row: row, claudeCode: claudeCode,
                                                   chatgpt: chatgpt, board: board,
                                                   antigravity: antigravity))
    }

    mutating func disappear() -> Effect? {
        guard active != nil else { return nil }
        active = nil
        return .hide
    }
}

/// 鼠标在档案行与统计面板之间移动时，面板显示哪一行。
/// 停在行上立即弹出、移到另一行立即切换；离开行或面板后不马上收起，界面等一小会儿再调用 settle()，
/// 那时既不在行上也不在面板上才收起——从行移到面板要经过两个窗口之间的空隙。
/// 只把有账号的行报进来（未登录的行不算行，停在上面等同于离开）。
struct StatsFlyoutHover: Equatable {
    /// 显示哪一行；nil 表示收起
    private(set) var row: StatsFlyoutRow?
    private var overRow: StatsFlyoutRow?
    private var overFlyout = false

    mutating func row(_ row: StatsFlyoutRow, hovering: Bool) {
        if hovering {
            overRow = row
            self.row = row
        } else if overRow == row {
            // 进入新行的通知可能先于离开旧行的到达：只清掉还记着的那一行
            overRow = nil
        }
    }

    mutating func flyout(hovering: Bool) {
        overFlyout = hovering
    }

    /// 离开后等待结束：既不在行上也不在面板上就收起
    mutating func settle() {
        if overRow == nil && !overFlyout { row = nil }
    }

    /// 档案列表变了：rows 是此刻各段全部有面板的行（StatsFlyoutRow.rows）。停着的行、或面板显示的那一行没了
    /// （删除、登出）时收不到离开，这里清掉；面板显示的那一行没了就立即收起
    mutating func rowsChanged(_ rows: Set<StatsFlyoutRow>) {
        if let overRow, !rows.contains(overRow) { self.overRow = nil }
        if let row, !rows.contains(row) { self = StatsFlyoutHover() }
    }

    /// 主面板关闭：立即收起
    mutating func dismiss() {
        self = StatsFlyoutHover()
    }
}

/// 统计面板窗口放在哪（AppKit 屏幕坐标，原点在左下）。每次显示、换行、内容大小变化、主面板移动时都按主面板
/// 此刻的位置重算，不缓存：主面板（MenuBarExtra 的窗口）过一夜后可能离开菜单栏往下掉（未解决），
/// 弹出面板跟着它，但无论主面板在哪都压在屏幕可用区域内，不会出界。
/// 竖直方向参照 iStat：面板里的内容与鼠标停着的那张卡片顶边对齐（面板窗口比卡片高出内边距），
/// 下面放不下时整体往上推，直到底边贴着可用区域。
enum StatsFlyoutPlacement {
    /// 内容是否高出可用区域、需要滚动（未超出时禁用滚动，同主面板 PanelView）
    static func isOverflowing(size: CGSize, within visible: CGRect) -> Bool {
        size.height > visible.height
    }

    /// - anchor: 主面板窗口此刻的位置
    /// - rowTop: 鼠标停着的那张卡片此刻的顶边（屏幕坐标）；还不知道时为 nil，面板顶边与主面板对齐
    /// - inset: 面板内容距窗口顶边的内边距（StatsFlyoutView.inset）
    /// - visible: 主面板所在屏幕的可用区域（visibleFrame）
    static func frame(size: CGSize, beside anchor: CGRect, rowTop: CGFloat? = nil, inset: CGFloat = 0,
                      within visible: CGRect, gap: CGFloat) -> CGRect {
        // 优先放左边；左边放不下就放右边；两边都放不下就压在屏幕内
        var x = anchor.minX - gap - size.width
        if x < visible.minX {
            let right = anchor.maxX + gap
            x = right + size.width <= visible.maxX ? right : max(visible.minX, min(x, visible.maxX - size.width))
        }
        // 比可用区域还高时窗口只有可用区域那么高，内容在里面滚动（不显示滚动条，StatsFlyoutRoot）
        let height = min(size.height, visible.height)
        // 内容顶边与卡片对齐（不知道卡片在哪时窗口顶边与主面板对齐），再压进可用区域
        let top = rowTop.map { $0 + inset } ?? anchor.maxY
        var y = min(top, visible.maxY) - height
        y = max(y, visible.minY)
        return CGRect(x: x, y: y, width: size.width, height: height)
    }
}
