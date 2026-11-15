// token-usage ticket 07：侧边统计面板显示什么（界面只按这些结果画）。
//
// 检查的接口（seam）：
//   QuotaRing.fiveHour / sevenDay(_:now:)   圆环卡：剩余百分比、颜色、重置倒计时
//   TokenFigure(_:period:)                  Token 用量卡与模型卡：主数字、四类、占比、起算点
//   HistoryBar.bars(_:)                     历史卡：每格四类与相对高度
//   StatsFlyoutTarget(profile:)             鼠标停在哪一行 → 显示哪个账号
//   StatsFlyoutHover                        鼠标在行与面板之间移动时弹出、切换、收起（行按 StatsFlyoutRow：工具 + 档案名）
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
            Check("停着的行被删除或登出（收不到离开）：立即收起；别的行变化不影响", hoveredRowDisappears),
            Check("位置：贴着主面板左侧，内容与停着的卡片顶边对齐；主面板往下掉或靠近屏幕边缘时不出界", placement),
            Check("历史悬停：按横向位置吸附到最近的一格，图外夹到两端；提示框放竖线右边，放不下换左边，不出卡片", historyHover),
            Check("顶层 tokenRequest 解析与生命周期：跨工具/Kimi/Antigravity/nil 连续切换不误关", tokenRequestLifecycle),
            Check("三类 Token 视图：排除缓存写入后主数字、占比、模型列表与历史柱高保持自洽", threeKindViews),
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
        let a = try unwrap(StatsFlyoutTarget(profile: work)), b = try unwrap(StatsFlyoutTarget(profile: work2))
        let c = try unwrap(StatsFlyoutTarget(profile: side))
        try expectEqual(a.account, b.account, "同一账号")
        try expectEqual(a.account.id, "account:u-1", "与账本记的账号一致")
        try expect(a.account != c.account, "不同账号")
        try expectEqual(a.email, "work@example.com")

        let loggedOut = Profile(name: "empty", configDir: "/nonexistent/empty",
                                claudeJSON: URL(fileURLWithPath: "/nonexistent/empty.json"), account: .loggedOut)
        try expect(StatsFlyoutTarget(profile: loggedOut) == nil, "未登录没有面板")
    }

    static func claude(_ name: String) -> StatsFlyoutRow { StatsFlyoutRow(tool: .claudeCode, name: name) }

    static func hover() throws {
        var hover = StatsFlyoutHover()
        try expectEqual(hover.row, nil)

        hover.row(claude("work"), hovering: true)
        try expectEqual(hover.row, claude("work"), "停在行上弹出")

        // 移到另一行：新行的进入可能先于旧行的离开到达
        hover.row(claude("side"), hovering: true)
        hover.row(claude("work"), hovering: false)
        hover.settle()
        try expectEqual(hover.row, claude("side"), "换成另一行")

        // 从行移到面板：离开行之后、等待结束之前进入面板，不收起
        hover.row(claude("side"), hovering: false)
        hover.flyout(hovering: true)
        hover.settle()
        try expectEqual(hover.row, claude("side"), "停在面板上不收起")

        // 都离开：等待结束时收起
        hover.flyout(hovering: false)
        try expectEqual(hover.row, claude("side"), "等待结束之前还在")
        hover.settle()
        try expectEqual(hover.row, nil, "都离开后收起")

        // 主面板关闭：立即收起
        hover.row(claude("work"), hovering: true)
        hover.dismiss()
        try expectEqual(hover.row, nil)
        hover.settle()
        try expectEqual(hover.row, nil)
    }

    static func hoveredRowDisappears() throws {
        var hover = StatsFlyoutHover()
        hover.row(claude("work"), hovering: true)
        hover.rowsChanged([claude("work"), claude("side")])
        try expectEqual(hover.row, claude("work"), "停着的行还在")
        hover.rowsChanged([claude("work")])
        try expectEqual(hover.row, claude("work"), "别的行没了不影响")

        // 停着的行被删除（或登出，不再报进来）：收不到离开，也要收起，之后不会再弹出来
        hover.rowsChanged([claude("side")])
        try expectEqual(hover.row, nil, "停着的行没了")
        hover.settle()
        try expectEqual(hover.row, nil)

        // 鼠标停在面板上时，面板显示的那一行没了：同样收起
        hover.row(claude("side"), hovering: true)
        hover.row(claude("side"), hovering: false)
        hover.flyout(hovering: true)
        hover.rowsChanged([])
        try expectEqual(hover.row, nil, "面板显示的那一行没了")
        hover.row(claude("work"), hovering: true)
        hover.row(claude("work"), hovering: false)
        hover.settle()
        try expectEqual(hover.row, nil, "面板已收起，不再算停在面板上")
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
        // 内容比可用区域还高：窗口只有可用区域那么高（内容在里面滚动），占满可用区域
        try expectEqual(place(CGRect(x: 1000, y: 0, width: 340, height: 400),
                              CGRect(x: 0, y: 0, width: 1440, height: 500)),
                        CGRect(x: 674, y: 0, width: 320, height: 500))
        // 是否溢出可用区域高度：放得下或刚好相等时为 false，超出时为 true
        try expectEqual(StatsFlyoutPlacement.isOverflowing(size: size, within: screen), false)
        try expectEqual(StatsFlyoutPlacement.isOverflowing(size: size, within: CGRect(x: 0, y: 0, width: 1440, height: 600)), false)
        try expectEqual(StatsFlyoutPlacement.isOverflowing(size: size, within: CGRect(x: 0, y: 0, width: 1440, height: 500)), true)
        // 副屏（原点不在 0）
        try expectEqual(place(CGRect(x: -500, y: 375, width: 340, height: 500),
                              CGRect(x: -1920, y: 0, width: 1920, height: 875)),
                        CGRect(x: -826, y: 275, width: 320, height: 600))

        func beside(row top: CGFloat, _ anchor: CGRect = CGRect(x: 1000, y: 75, width: 340, height: 800),
                    height: CGFloat = 600) -> CGRect {
            StatsFlyoutPlacement.frame(size: CGSize(width: 320, height: height), beside: anchor, rowTop: top,
                                       inset: 8, within: screen, gap: 6)
        }
        // 停在卡片上：面板内容与卡片顶边对齐，窗口顶边高出内边距
        try expectEqual(beside(row: 700), CGRect(x: 674, y: 108, width: 320, height: 600))
        // 卡片靠下、下面放不下：往上推到底边贴着可用区域
        try expectEqual(beside(row: 300), CGRect(x: 674, y: 0, width: 320, height: 600))
        // 第一张卡片离菜单栏不到内边距：窗口顶边不出可用区域
        try expectEqual(beside(row: 870), CGRect(x: 674, y: 275, width: 320, height: 600))
        // 面板矮：仍跟着卡片
        try expectEqual(beside(row: 400, height: 200), CGRect(x: 674, y: 208, width: 320, height: 200))
    }

    static func historyHover() throws {
        // 24 格铺满 240pt 宽：每格 10pt
        try expectEqual(HistoryHover.index(x: 0, width: 240, count: 24), 0)
        try expectEqual(HistoryHover.index(x: 9.9, width: 240, count: 24), 0)
        try expectEqual(HistoryHover.index(x: 10, width: 240, count: 24), 1)
        try expectEqual(HistoryHover.index(x: 239, width: 240, count: 24), 23)
        try expectEqual(HistoryHover.index(x: -5, width: 240, count: 24), 0, "图左外")
        try expectEqual(HistoryHover.index(x: 300, width: 240, count: 24), 23, "图右外")
        try expectEqual(HistoryHover.index(x: 10, width: 240, count: 0), nil, "没有格子")
        try expectEqual(HistoryHover.index(x: 10, width: 0, count: 24), nil, "还没量出宽度")
        // 竖线在格子正中
        try expectEqual(HistoryHover.lineX(index: 1, width: 240, count: 24), 15)
        // 提示框 100pt 宽，与竖线隔 6pt
        try expectEqual(HistoryHover.tooltipX(lineX: 15, tooltipWidth: 100, width: 240, gap: 6), 21, "右边放得下")
        try expectEqual(HistoryHover.tooltipX(lineX: 200, tooltipWidth: 100, width: 240, gap: 6), 94, "换到左边")
        try expectEqual(HistoryHover.tooltipX(lineX: 120, tooltipWidth: 300, width: 240, gap: 6), 0, "比卡片还宽：贴左")
    }

    static func tokenRequestLifecycle() throws {
        let claudeWork = LiveQuotaMergeChecks.profile("work", uuid: "u-1")
        let claudeWork2 = LiveQuotaMergeChecks.profile("work2", uuid: "u-1")
        let claudeOut = Profile(name: "empty", configDir: "/nonexistent/empty",
                                claudeJSON: URL(fileURLWithPath: "/nonexistent/empty.json"), account: .loggedOut)
        let chatgptWork = ChatGPTProfile(
            name: "work", codexHome: nil, directory: "/tmp/codex-work",
            account: ChatGPTAccount(email: "cg@example.com", planType: "plus", userID: "user-1", workspaceID: "ws-1"),
            status: .canRequestUsage)
        let chatgptOut = ChatGPTProfile(name: "empty", codexHome: nil, directory: "/tmp/codex-empty",
                                        account: nil, status: .notLoggedIn)

        let claudeAccount = UsageAccount(id: "account:u-1")
        let chatgptAccount = UsageAccount(id: "chatgpt:user-1:ws-1")
        var board = UsageBoard()
        let claudeResets = at(minutes: 90)
        let chatgptResets = at(minutes: 180)
        board.recordLive([LiveQuota(profile: "work", receivedAt: now,
                                    fiveHour: UsageWindow(utilization: 20, resetsAt: claudeResets),
                                    sevenDay: nil)],
                         profiles: [claudeWork])
        board.recordLive(LiveQuota(profile: "work", receivedAt: now,
                                   fiveHour: UsageWindow(utilization: 10, resetsAt: chatgptResets),
                                   sevenDay: nil),
                         for: chatgptAccount)

        let antigravityAccount = UsageAccount(id: "antigravity:a@example.com")
        var antigravityBoard = AntigravityBoard()
        antigravityBoard.add("A@Example.com")
        let agFiveHour = at(minutes: 240)
        let agWeekly = at(minutes: 3000)
        antigravityBoard.record(.success(AntigravityAccountQuota(
            email: "a@example.com", tierName: "Pro", tierId: nil,
            groups: [
                AntigravityQuotaGroup(
                    kind: .gemini, displayName: "Gemini Models", models: [],
                    buckets: [AntigravityQuotaBucket(bucketId: "g-5h", displayName: nil, window: .fiveHour,
                                                    usage: UsageWindow(utilization: 20, resetsAt: agFiveHour))]),
                AntigravityQuotaGroup(
                    kind: .thirdParty, displayName: "Claude and GPT models", models: [],
                    buckets: [AntigravityQuotaBucket(bucketId: "3p-w", displayName: nil, window: .weekly,
                                                    usage: UsageWindow(utilization: 10, resetsAt: agWeekly))]),
            ],
            fetchedAt: now)), clicked: nil)
        let antigravityReq = StatsFlyoutTokenRequest(
            account: antigravityAccount,
            resets: KnownResets(fiveHour: agFiveHour, sevenDay: agWeekly))

        let claudeReq = StatsFlyoutTokenRequest(account: claudeAccount,
                                                resets: KnownResets(fiveHour: claudeResets, sevenDay: nil))
        let chatgptReq = StatsFlyoutTokenRequest(account: chatgptAccount,
                                                 resets: KnownResets(fiveHour: chatgptResets, sevenDay: nil))

        let claudeProfiles = [claudeWork, claudeWork2, claudeOut]
        let chatgptProfiles = [chatgptWork, chatgptOut]

        try expectEqual(StatsFlyoutTokenRequest.resolve(row: claude("work"), claudeCode: claudeProfiles,
                                                        chatgpt: chatgptProfiles, board: board,
                                                        antigravity: antigravityBoard),
                        claudeReq)
        try expectEqual(StatsFlyoutTokenRequest.resolve(row: claude("empty"), claudeCode: claudeProfiles,
                                                        chatgpt: chatgptProfiles, board: board,
                                                        antigravity: antigravityBoard),
                        nil, "未登录 Claude 档案没有请求")
        try expectEqual(StatsFlyoutTokenRequest.resolve(row: StatsFlyoutRow(tool: .chatgpt, name: "work"),
                                                        claudeCode: claudeProfiles, chatgpt: chatgptProfiles,
                                                        board: board, antigravity: antigravityBoard),
                        chatgptReq)
        try expectEqual(StatsFlyoutTokenRequest.resolve(row: StatsFlyoutRow(tool: .chatgpt, name: "empty"),
                                                        claudeCode: claudeProfiles, chatgpt: chatgptProfiles,
                                                        board: board, antigravity: antigravityBoard),
                        nil, "未登录 ChatGPT 档案没有请求")
        try expectEqual(StatsFlyoutTokenRequest.resolve(row: .kimi("main"), claudeCode: claudeProfiles,
                                                        chatgpt: chatgptProfiles, board: board,
                                                        antigravity: antigravityBoard),
                        nil, "Kimi 没有 Token 请求")
        try expectEqual(StatsFlyoutTokenRequest.resolve(row: .antigravity("A@Example.com"),
                                                        claudeCode: claudeProfiles, chatgpt: chatgptProfiles,
                                                        board: board, antigravity: antigravityBoard),
                        antigravityReq, "Antigravity 解析为 antigravity:<小写邮箱> 并带池优先级 KnownResets")
        try expectEqual(StatsFlyoutTokenRequest.resolve(row: .antigravity("  "),
                                                        claudeCode: claudeProfiles, chatgpt: chatgptProfiles,
                                                        board: board, antigravity: antigravityBoard),
                        nil, "空白 Antigravity 卡片行不得解析出请求")
        try expectEqual(antigravityAccount.isAntigravity, true)
        try expectEqual(claudeAccount.isAntigravity, false)
        try expectEqual(chatgptAccount.isAntigravity, false)
        try expectEqual(UsageAccount.antigravity(email: "  A@Example.com \n"), antigravityAccount)
        try expectEqual(UsageAccount.antigravity(email: "invalid-no-at"), nil)
        try expectEqual(UsageAccount.antigravity(email: nil), nil)
        try expectEqual(UsageAccount.antigravity(cardEmail: " A@Example.com "), antigravityAccount)
        try expectEqual(AntigravityBoard.normalizedEmail(" User@Example.com "), "user@example.com")
        try expectEqual(AntigravityBoard.normalizedEmail("   "), nil)
        try expectEqual(StatsFlyoutTokenRequest.resolve(row: nil, claudeCode: claudeProfiles,
                                                        chatgpt: chatgptProfiles, board: board,
                                                        antigravity: antigravityBoard),
                        nil)

        // 连续切换：claude -> chatgpt -> kimi -> antigravity -> claude -> nil
        var lifecycle = StatsFlyoutTokenLifecycle()
        try expectEqual(lifecycle.update(row: nil, claudeCode: claudeProfiles, chatgpt: chatgptProfiles,
                                         board: board, antigravity: antigravityBoard),
                        nil, "初始为空时不重复 hide")
        try expectEqual(lifecycle.update(row: claude("work"), claudeCode: claudeProfiles, chatgpt: chatgptProfiles,
                                         board: board, antigravity: antigravityBoard),
                        .show(claudeReq))
        // 同账号的另一个档案：请求不变，不触发新操作
        try expectEqual(lifecycle.update(row: claude("work2"), claudeCode: claudeProfiles, chatgpt: chatgptProfiles,
                                         board: board, antigravity: antigravityBoard),
                        nil)
        // 快速切到 ChatGPT（同名 "work"）
        try expectEqual(lifecycle.update(row: StatsFlyoutRow(tool: .chatgpt, name: "work"),
                                         claudeCode: claudeProfiles, chatgpt: chatgptProfiles,
                                         board: board, antigravity: antigravityBoard),
                        .show(chatgptReq))
        // 切到 Kimi：收到 hide
        try expectEqual(lifecycle.update(row: .kimi("main"), claudeCode: claudeProfiles, chatgpt: chatgptProfiles,
                                         board: board, antigravity: antigravityBoard),
                        .hide)
        // 切到 Antigravity：收到 show(antigravityReq)
        try expectEqual(lifecycle.update(row: .antigravity("A@Example.com"),
                                         claudeCode: claudeProfiles, chatgpt: chatgptProfiles,
                                         board: board, antigravity: antigravityBoard),
                        .show(antigravityReq))
        // 立刻切回 Claude
        try expectEqual(lifecycle.update(row: claude("work"), claudeCode: claudeProfiles, chatgpt: chatgptProfiles,
                                         board: board, antigravity: antigravityBoard),
                        .show(claudeReq))
        // Claude -> nil
        try expectEqual(lifecycle.update(row: nil, claudeCode: claudeProfiles, chatgpt: chatgptProfiles,
                                         board: board, antigravity: antigravityBoard),
                        .hide)
        // 容器整体消失：只在有活跃请求时 hide
        try expectEqual(lifecycle.disappear(), nil)
        _ = lifecycle.update(row: claude("work"), claudeCode: claudeProfiles, chatgpt: chatgptProfiles,
                             board: board, antigravity: antigravityBoard)
        try expectEqual(lifecycle.disappear(), .hide)
        try expectEqual(lifecycle.active, nil)
    }

    static func threeKindViews() throws {
        try expectEqual(TokenKind.withoutCacheWrite, [.input, .output, .cacheRead])

        let sample = counts(6_000, 11_000, 500_000, 937_000)
        try expectEqual(sample.total(for: TokenKind.allCases), 1_454_000)
        try expectEqual(sample.total(for: TokenKind.withoutCacheWrite), 954_000)

        // 即使原始明细带有 cacheWrite，3 类视图也严格以 [.input, .output, .cacheRead] 计算合计与分母
        let five = breakdown([
            ("Gemini 3.1 Pro", counts(6_000, 11_000, 500_000, 937_000)), // 3类=954_000
            ("Cache Only", counts(0, 0, 200_000, 0)),                      // 3类=0（应隐藏）
            ("Gemini 3 Flash", counts(0, 46_000, 0, 0)),                   // 3类=46_000
        ])
        let onlyCacheWrite = breakdown([("Cache Only", counts(0, 0, 50_000, 0))])
        let origin = at(minutes: -120)
        let hourly = [
            TokenUsageBucket(start: at(minutes: -120), tokens: counts(0, 0, 1_000, 0)), // 3类=0
            TokenUsageBucket(start: at(minutes: -60), tokens: counts(10, 20, 500, 20)), // 3类=50
            TokenUsageBucket(start: at(minutes: 0), tokens: counts(0, 0, 100, 200)),   // 3类=200
        ]
        let usage = tokenUsage(fiveHour: five, sevenDay: onlyCacheWrite, cumulative: five,
                               origin: origin, hourly: hourly)

        // 默认仍是 4 类
        let defaultFigure = TokenFigure(usage, period: .fiveHour)
        try expectEqual(defaultFigure.kinds, TokenKind.allCases)
        try expectEqual(defaultFigure.parts.map(\.kind), [.input, .output, .cacheWrite, .cacheRead])

        // 3 类模式：总计 1,000,000 -> "1.0M"
        let figure = TokenFigure(usage, period: .fiveHour, kinds: TokenKind.withoutCacheWrite)
        try expectEqual(figure.kinds, TokenKind.withoutCacheWrite)
        try expectEqual(figure.total, "1.0M")
        try expectEqual(figure.since, nil)
        try expectEqual(figure.parts.map(\.kind), [.input, .output, .cacheRead])
        try expectEqual(figure.parts.map(\.value), ["6.0K", "57.0K", "937.0K"])
        try expectEqual(figure.parts.map(\.share), ["<1%", "6%", "94%"])
        try expect(abs(figure.parts[1].fraction - 57.0 / 1000.0) < 1e-9, "3类输出占比 \(figure.parts[1].fraction)")
        try expectEqual(figure.models, [
            TokenFigure.ModelRow(name: "Gemini 3.1 Pro", value: "954.0K", share: "95%"),
            TokenFigure.ModelRow(name: "Gemini 3 Flash", value: "46.0K", share: "5%"),
        ])

        // 累计保留起算点
        let cumulative = TokenFigure(usage, period: .cumulative, kinds: TokenKind.withoutCacheWrite)
        try expectEqual(cumulative.since, origin)
        try expectEqual(cumulative.total, "1.0M")

        // 仅有 cacheWrite 时，3 类总计为 0 且不显示该模型
        let emptyThreeKind = TokenFigure(usage, period: .sevenDay, kinds: TokenKind.withoutCacheWrite)
        try expectEqual(emptyThreeKind.total, "0")
        try expectEqual(emptyThreeKind.parts.map(\.value), ["0", "0", "0"])
        try expectEqual(emptyThreeKind.parts.map(\.share), ["0%", "0%", "0%"])
        try expectEqual(emptyThreeKind.parts.map(\.fraction), [0, 0, 0])
        try expectEqual(emptyThreeKind.models, [])

        // 历史柱高按 3 类最大格子归一化（第 1 格 cacheWrite=1000 不影响，3类最大为 200）
        let bars = HistoryBar.bars(usage, range: .hours, kinds: TokenKind.withoutCacheWrite)
        try expectEqual(bars.map(\.height), [0, 0.25, 1])
    }
}
