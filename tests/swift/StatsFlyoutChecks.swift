// token-usage ticket 07：侧边统计面板显示什么（界面只按这些结果画）。
//
// 检查的接口（seam）：
//   QuotaRing.fiveHour / sevenDay(_:now:)   圆环卡：剩余百分比、颜色、重置倒计时
//   TokenFigure(_:period:)                  Token 用量卡与模型卡：主数字、四类、占比、起算点
//   HistoryBar.bars(_:)                     历史卡：每格四类与相对高度
//   StatsFlyoutTarget(profile:)             鼠标停在哪一行 → 显示哪个账号
//   StatsFlyoutHover                        鼠标在行与面板之间移动时弹出、切换、收起
// 期望值都是手算的。

import Foundation

final class StatsFlyoutChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("圆环：有数字时画弧并按内置阈值着色，下方是重置倒计时；没有数据、已重置待刷新显示—不画弧", rings),
            Check("Token 用量：按分段取窗口或累计，主数字简写，四类按固定顺序给值和占比，模型跟随分段", figures),
            Check("Token 用量为 0：照常显示 0 和 0%，不画比例", zeroFigure),
            Check("历史：24 小时取每小时、30 天取每天，柱高按最高的一格算，全为 0 时都不画", history),
            Check("哪一行显示哪个账号：同一账号的多个档案显示同一份；未登录的档案没有面板", targets),
            Check("鼠标停在行上弹出，移到另一行就换，移到面板上不收起，都离开后收起", hover),
            Check("位置：贴着主面板左侧、顶边对齐；主面板往下掉或靠近屏幕边缘时不出界", placement),
        ]
    }

    static let now = fixedNow
    static func at(minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    static func rings() throws {
        // 已用 38.4% → 剩余 61%（绿），2 小时 13 分后重置；周窗口已用 85% → 剩余 15%（红）
        let snapshot = UsageSnapshot(fiveHour: UsageWindow(utilization: 38.4, resetsAt: at(minutes: 133)),
                                     sevenDay: UsageWindow(utilization: 85, resetsAt: at(minutes: 3 * 1440 + 300)),
                                     fetchedAt: at(minutes: -5))
        let usage = AccountUsage(snapshot: snapshot)
        try expectEqual(QuotaRing.fiveHour(usage, now: now),
                        QuotaRing(remaining: 61, tint: .green, countdown: .hoursMinutes(2, 13)))
        try expectEqual(QuotaRing.sevenDay(usage, now: now),
                        QuotaRing(remaining: 15, tint: .red, countdown: .daysHours(3, 5)))

        // 数据超过 30 分钟：数字照常、弧变灰
        try expectEqual(QuotaRing.fiveHour(usage, now: at(minutes: 40)),
                        QuotaRing(remaining: 61, tint: .stale, countdown: .hoursMinutes(1, 33)))

        // 过了重置时间（待刷新）：不画弧、没有倒计时
        try expectEqual(QuotaRing.fiveHour(usage, now: at(minutes: 133)), QuotaRing.empty)

        // 从没拿到过额度
        try expectEqual(QuotaRing.fiveHour(nil, now: now), QuotaRing.empty)
        try expectEqual(QuotaRing.sevenDay(AccountUsage(), now: now), QuotaRing.empty)
    }

    static func counts(_ input: Int, _ output: Int, _ cacheWrite: Int, _ cacheRead: Int) -> TokenCounts {
        TokenCounts(input: input, output: output, cacheWrite: cacheWrite, cacheRead: cacheRead)
    }

    static func breakdown(_ models: [(String, TokenCounts)]) -> TokenUsageBreakdown {
        TokenUsageBreakdown(tokens: models.map(\.1).reduce(.zero, +),
                            byModel: models.map { ModelTokenUsage(model: $0.0, tokens: $0.1) })
    }

    static func tokenUsage(fiveHour: TokenUsageBreakdown = .empty, sevenDay: TokenUsageBreakdown = .empty,
                           cumulative: TokenUsageBreakdown = .empty, origin: Date? = nil,
                           hourly: [TokenUsageBucket] = [], daily: [TokenUsageBucket] = []) -> AccountTokenUsage {
        AccountTokenUsage(fiveHour: TokenUsageWindow(start: at(minutes: -60), end: at(minutes: 240), usage: fiveHour),
                          sevenDay: TokenUsageWindow(start: at(minutes: -1440), end: at(minutes: 1440), usage: sevenDay),
                          cumulative: TokenUsageCumulative(origin: origin, usage: cumulative),
                          hourly: hourly, daily: daily)
    }

    static func figures() throws {
        // 5 小时窗口：Opus 5.5 共 1 000 000（输入 6 000、输出 12 000、缓存写入 45 000、缓存读取 937 000），
        // Sonnet 5.5 共 4 000（只有输出）→ 合计 1 004 000
        let five = breakdown([("Opus 5.5", counts(6_000, 12_000, 45_000, 937_000)),
                              ("Sonnet 5.5", counts(0, 4_000, 0, 0))])
        let cumulative = breakdown([("Opus 5.5", counts(1, 2, 3, 2_345_678_895))])
        let origin = at(minutes: -30 * 1440)
        let usage = tokenUsage(fiveHour: five, sevenDay: five, cumulative: cumulative, origin: origin)

        let figure = TokenFigure(usage, period: .fiveHour)
        try expectEqual(figure.total, "1.0M")
        try expectEqual(figure.since, nil, "窗口不标起算点")
        try expectEqual(figure.parts.map(\.kind), [.input, .output, .cacheWrite, .cacheRead])
        try expectEqual(figure.parts.map(\.value), ["6.0K", "16.0K", "45.0K", "937.0K"])
        try expectEqual(figure.parts.map(\.share), ["<1%", "2%", "4%", "93%"])
        // 比例条的长度：16 000 / 1 004 000
        try expect(abs(figure.parts[1].fraction - 16.0 / 1004) < 1e-9, "输出的比例 \(figure.parts[1].fraction)")
        try expectEqual(figure.models, [TokenFigure.ModelRow(name: "Opus 5.5", value: "1.0M", share: "100%"),
                                        TokenFigure.ModelRow(name: "Sonnet 5.5", value: "4.0K", share: "<1%")])

        let total = TokenFigure(usage, period: .cumulative)
        try expectEqual(total.total, "2.35B")
        try expectEqual(total.since, origin, "累计标出起算点")
        try expectEqual(total.parts.map(\.share), ["<1%", "<1%", "<1%", "100%"])
        try expectEqual(total.models.map(\.name), ["Opus 5.5"])
    }

    static func zeroFigure() throws {
        let figure = TokenFigure(tokenUsage(origin: at(minutes: -10)), period: .sevenDay)
        try expectEqual(figure.total, "0")
        try expectEqual(figure.parts.map(\.value), ["0", "0", "0", "0"])
        try expectEqual(figure.parts.map(\.share), ["0%", "0%", "0%", "0%"])
        try expectEqual(figure.parts.map(\.fraction), [0, 0, 0, 0])
        try expectEqual(figure.models, [])
    }

    static func history() throws {
        let hourly = [TokenUsageBucket(start: at(minutes: -120), tokens: .zero),
                      TokenUsageBucket(start: at(minutes: -60), tokens: counts(10, 20, 0, 20)),
                      TokenUsageBucket(start: at(minutes: 0), tokens: counts(0, 0, 0, 200))]
        let daily = [TokenUsageBucket(start: at(minutes: -1440), tokens: .zero),
                     TokenUsageBucket(start: at(minutes: 0), tokens: .zero)]
        let usage = tokenUsage(hourly: hourly, daily: daily)

        let hours = HistoryBar.bars(usage, range: .hours)
        try expectEqual(hours.map(\.start), hourly.map(\.start))
        try expectEqual(hours.map(\.tokens), hourly.map(\.tokens))
        try expectEqual(hours.map(\.height), [0, 0.25, 1])

        let days = HistoryBar.bars(usage, range: .days)
        try expectEqual(days.map(\.start), daily.map(\.start))
        try expectEqual(days.map(\.height), [0, 0])
    }

    static func targets() throws {
        let work = LiveQuotaMergeChecks.profile("work", uuid: "u-1")
        let work2 = LiveQuotaMergeChecks.profile("work2", uuid: "u-1")
        let side = LiveQuotaMergeChecks.profile("side", uuid: "u-2")
        let a = try expectSome(StatsFlyoutTarget(profile: work)), b = try expectSome(StatsFlyoutTarget(profile: work2))
        let c = try expectSome(StatsFlyoutTarget(profile: side))
        try expectEqual(a.account, b.account, "同一账号")
        try expectEqual(a.account.id, "account:u-1", "与账本记的账号一致")
        try expect(a.account != c.account, "不同账号")
        try expectEqual(a.email, "work@example.com")

        let loggedOut = Profile(name: "empty", configDir: "/nonexistent/empty",
                                claudeJSON: URL(fileURLWithPath: "/nonexistent/empty.json"), account: .loggedOut)
        try expect(StatsFlyoutTarget(profile: loggedOut) == nil, "未登录没有面板")
    }

    static func expectSome<T>(_ value: T?, file: StaticString = #fileID, line: UInt = #line) throws -> T {
        guard let value else { throw CheckFailure(description: "\(file):\(line): 不应为 nil") }
        return value
    }

    static func hover() throws {
        var hover = StatsFlyoutHover()
        try expectEqual(hover.profile, nil)

        hover.row("work", hovering: true)
        try expectEqual(hover.profile, "work", "停在行上弹出")

        // 移到另一行：新行的进入可能先于旧行的离开到达
        hover.row("side", hovering: true)
        hover.row("work", hovering: false)
        hover.settle()
        try expectEqual(hover.profile, "side", "换成另一行")

        // 从行移到面板：离开行之后、等待结束之前进入面板，不收起
        hover.row("side", hovering: false)
        hover.flyout(hovering: true)
        hover.settle()
        try expectEqual(hover.profile, "side", "停在面板上不收起")

        // 都离开：等待结束时收起
        hover.flyout(hovering: false)
        try expectEqual(hover.profile, "side", "等待结束之前还在")
        hover.settle()
        try expectEqual(hover.profile, nil, "都离开后收起")

        // 主面板关闭：立即收起
        hover.row("work", hovering: true)
        hover.dismiss()
        try expectEqual(hover.profile, nil)
        hover.settle()
        try expectEqual(hover.profile, nil)
    }

    static func placement() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)   // 可用区域（不含菜单栏、程序坞）
        let size = CGSize(width: 320, height: 600)
        func place(_ anchor: CGRect, _ visible: CGRect = screen) -> CGRect {
            StatsFlyoutPlacement.frame(size: size, beside: anchor, within: visible, gap: 6)
        }
        // 正常：主面板挂在菜单栏下（顶边 875），弹出面板在它左边 6pt，顶边对齐
        try expectEqual(place(CGRect(x: 1000, y: 375, width: 340, height: 500)),
                        CGRect(x: 674, y: 275, width: 320, height: 600))
        // 主面板过夜后往下掉了一截：仍贴着它，但底边不出屏幕
        try expectEqual(place(CGRect(x: 1000, y: -200, width: 340, height: 500)),
                        CGRect(x: 674, y: 0, width: 320, height: 600))
        // 主面板顶边高出可用区域：弹出面板顶边压到可用区域内
        try expectEqual(place(CGRect(x: 1000, y: 500, width: 340, height: 500)),
                        CGRect(x: 674, y: 275, width: 320, height: 600))
        // 主面板靠近屏幕左边：放到右边
        try expectEqual(place(CGRect(x: 100, y: 375, width: 340, height: 500)),
                        CGRect(x: 446, y: 275, width: 320, height: 600))
        // 两边都放不下：压在屏幕内
        try expectEqual(place(CGRect(x: 50, y: 375, width: 340, height: 500),
                              CGRect(x: 0, y: 0, width: 500, height: 875)),
                        CGRect(x: 0, y: 275, width: 320, height: 600))
        // 屏幕比弹出面板还矮：保住顶部
        try expectEqual(place(CGRect(x: 1000, y: 0, width: 340, height: 400),
                              CGRect(x: 0, y: 0, width: 1440, height: 500)),
                        CGRect(x: 674, y: -100, width: 320, height: 600))
        // 副屏（原点不在 0）
        try expectEqual(place(CGRect(x: -500, y: 375, width: 340, height: 500),
                              CGRect(x: -1920, y: 0, width: 1920, height: 875)),
                        CGRect(x: -826, y: 275, width: 320, height: 600))
    }
}
