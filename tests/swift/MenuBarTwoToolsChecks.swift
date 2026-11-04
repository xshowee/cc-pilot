// chatgpt-profiles ticket 11：菜单栏同时显示两个工具。
// 接口：UsageBoard.menuBarContent(claudeCode:profiles:chatgpt:chatgptProfiles:reportedPlans:preferences:now:)
// → MenuBarContent（两个工具：每行一个工具的 5 小时剩余；一个工具：原来的"套餐 / 5 小时剩余"两行）。
// 期望值来自 spec "菜单栏" 一节与现有菜单栏规则（MenuBarSummaryChecks），数字手写。
// 看板直接用 record 喂刷新结果（不经网络层）；ChatGPT 档案直接构造（解析 auth.json 由 ChatGPTProfileChecks 覆盖）。

import Foundation

final class MenuBarTwoToolsChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("两个工具都显示时每行一个工具：各自当前档案的 5 小时剩余，不显示套餐", twoToolsLines),
            Check("两个工具的行各自按阈值着色、变灰；没有数据是—，过了重置时间是已重置", twoToolsTintsAndPlaceholders),
            Check("隐藏 ChatGPT 或没有 ChatGPT 默认档案时保持 Claude 的套餐 / 5 小时剩余两行", claudeOnly),
            Check("隐藏 Claude Code 时显示 ChatGPT 的套餐 / 5 小时剩余两行", chatgptOnly),
            Check("ChatGPT 单独显示时套餐取最近一次刷新响应里的，没有时取 auth.json，都没有时是档案名", chatgptTitle),
            Check("两个工具都被隐藏时仍显示 Claude Code（保守默认）", bothHidden),
            Check("当前档案不存在或未登录时那一行是—", missingCurrentProfile),
        ]
    }

    // MARK: - 夹具

    static let claudeAccount = UsageAccount(id: "account:u-claude")

    static func chatgptProfile(_ name: String, plan: String? = "plus", userID: String? = "user-me",
                               workspaceID: String? = "ws-1") -> ChatGPTProfile {
        let account = userID == nil
            ? nil
            : ChatGPTAccount(email: "me@example.com", planType: plan, userID: userID, workspaceID: workspaceID)
        return ChatGPTProfile(name: name, codexHome: nil, directory: "/nonexistent/.codex", account: account,
                              status: account == nil ? .notLoggedIn : .canRequestUsage)
    }

    static let chatgptAccount = UsageAccount(id: "chatgpt:user-me:ws-1")

    /// 剩余 remaining%、resetsIn 秒后重置、fetchedAgo 秒前获取的刷新结果
    static func record(_ board: inout UsageBoard, _ account: UsageAccount, remaining: Double,
                       resetsIn: TimeInterval = 3600, fetchedAgo: TimeInterval = 60) {
        let window = UsageWindow(utilization: 100 - remaining, resetsAt: fixedNow.addingTimeInterval(resetsIn))
        let snapshot = UsageSnapshot(fiveHour: window, sevenDay: nil, fetchedAt: fixedNow.addingTimeInterval(-fetchedAgo))
        board.record(UsageRefreshOutcome(account: account, result: .success(snapshot)))
    }

    /// 一个已登录 Claude 档案 "work"（Max 20x，账号 u-claude）
    static func claudeProfiles(_ home: TempHome) throws -> [Profile] {
        try home.makeLoggedInProfile("work", uuid: "u-claude", orgType: "claude_max",
                                     rateLimitTier: "default_claude_max_20x")
        return Array(home.profilesWithLogin().values)
    }

    static func content(_ board: UsageBoard, claude: [Profile], claudeCurrent: String = "work",
                        chatgpt: [ChatGPTProfile], chatgptCurrent: String = "default",
                        reportedPlans: [UsageAccount: String] = [:],
                        hides: MenuBarToolPreferences = MenuBarToolPreferences()) -> MenuBarContent {
        board.menuBarContent(claudeCode: claudeCurrent, profiles: claude,
                             chatgpt: chatgptCurrent, chatgptProfiles: chatgpt, reportedPlans: reportedPlans,
                             preferences: hides, now: fixedNow)
    }

    static func lines(_ content: MenuBarContent) throws -> [MenuBarToolLine] {
        guard case .twoTools(let first, let second) = content else {
            throw CheckFailure(description: "期望两个工具各一行，得到 \(content)")
        }
        return [first, second]
    }

    static func single(_ content: MenuBarContent) throws -> MenuBarSummary {
        guard case .single(let summary) = content else {
            throw CheckFailure(description: "期望一个工具的两行，得到 \(content)")
        }
        return summary
    }

    static let tierName: (SubscriptionTier) -> String = { $0 == .max(multiplier: 20) ? "Max 20x" : "?" }
    static let planName: (String) -> String = { $0 == "pro" ? "Pro" : $0 == "plus" ? "Plus" : "?" + $0 }

    // MARK: - 检查

    static func twoToolsLines() throws {
        let home = try TempHome()
        defer { home.remove() }
        var board = UsageBoard()
        record(&board, claudeAccount, remaining: 42)
        record(&board, chatgptAccount, remaining: 87)

        let rows = try lines(content(board, claude: try claudeProfiles(home), chatgpt: [chatgptProfile("default")]))
        try expectEqual(rows.map(\.tool), [.claudeCode, .chatgpt], "Claude Code 在上、ChatGPT 在下")
        try expectEqual(rows.map { $0.quotaLine(resetText: "Reset") }, ["42%", "87%"])
        try expectEqual(rows.map(\.profileName), ["work", "default"])
    }

    static func twoToolsTintsAndPlaceholders() throws {
        let home = try TempHome()
        defer { home.remove() }
        let claude = try claudeProfiles(home)
        let chatgpt = [chatgptProfile("default")]

        var board = UsageBoard()
        record(&board, claudeAccount, remaining: 15)
        record(&board, chatgptAccount, remaining: 60, fetchedAgo: 31 * 60)
        var rows = try lines(content(board, claude: claude, chatgpt: chatgpt))
        try expectEqual(rows.map(\.quotaTint), [.red, .stale], "≤20 红；超过 30 分钟变灰")
        try expectEqual(rows.map { $0.quotaLine(resetText: "Reset") }, ["15%", "60%"])

        board = UsageBoard()
        record(&board, chatgptAccount, remaining: 40, resetsIn: -60)
        rows = try lines(content(board, claude: claude, chatgpt: chatgpt))
        try expectEqual(rows.map { $0.quotaLine(resetText: "已重置") }, ["—", "已重置"])
        try expectEqual(rows.map(\.quotaTint), [.plain, .plain], "没有数字时不着色")
    }

    static func claudeOnly() throws {
        let home = try TempHome()
        defer { home.remove() }
        let claude = try claudeProfiles(home)
        var board = UsageBoard()
        record(&board, claudeAccount, remaining: 42)
        record(&board, chatgptAccount, remaining: 87)

        let expected = MenuBarSummary(profileName: "work", fiveHour: .remaining(42, tint: .yellow),
                                      tier: .max(multiplier: 20))
        let hidden = try single(content(board, claude: claude, chatgpt: [chatgptProfile("default")],
                                        hides: MenuBarToolPreferences(hidesChatGPT: true)))
        try expectEqual(hidden, expected, "隐藏 ChatGPT")
        try expectEqual(hidden.titleLine(tierName: tierName), "Max 20x")
        try expectEqual(hidden.quotaLine(resetText: "Reset"), "42%")

        // 没有 ~/.codex 时 ChatGPT 档案列表为空（ChatGPTProfileStore.listProfiles）
        try expectEqual(try single(content(board, claude: claude, chatgpt: [])), expected, "没有 ChatGPT 默认档案")
        try expectEqual(try single(content(board, claude: claude, chatgpt: [],
                                           hides: MenuBarToolPreferences(hidesChatGPT: true))), expected)
    }

    static func chatgptOnly() throws {
        let home = try TempHome()
        defer { home.remove() }
        var board = UsageBoard()
        record(&board, claudeAccount, remaining: 42)
        record(&board, chatgptAccount, remaining: 87)

        let summary = try single(content(board, claude: try claudeProfiles(home),
                                         chatgpt: [chatgptProfile("default"), chatgptProfile("team", plan: "team",
                                                                                              userID: "user-2")],
                                         hides: MenuBarToolPreferences(hidesClaudeCode: true)))
        try expectEqual(summary.tool, .chatgpt)
        try expectEqual(summary.profileName, "default")
        try expectEqual(summary.titleLine(tierName: tierName, planName: planName), "Plus")
        try expectEqual(summary.quotaLine(resetText: "Reset"), "87%")
        try expectEqual(summary.quotaTint, .green)
    }

    static func chatgptTitle() throws {
        let home = try TempHome()
        defer { home.remove() }
        let claude = try claudeProfiles(home)
        let board = UsageBoard()
        let hides = MenuBarToolPreferences(hidesClaudeCode: true)
        func title(_ profile: ChatGPTProfile, reported: [UsageAccount: String] = [:]) throws -> String {
            try single(content(board, claude: claude, chatgpt: [profile], chatgptCurrent: profile.name,
                               reportedPlans: reported, hides: hides))
                .titleLine(tierName: tierName, planName: planName)
        }
        try expectEqual(try title(chatgptProfile("default", plan: "plus"), reported: [chatgptAccount: "pro"]), "Pro",
                        "响应里的套餐比 auth.json 新")
        try expectEqual(try title(chatgptProfile("default", plan: "plus")), "Plus")
        try expectEqual(try title(chatgptProfile("default", plan: nil)), "default", "不知道套餐")
        try expectEqual(try title(chatgptProfile("default", userID: nil)), "default", "未登录")
    }

    static func bothHidden() throws {
        let home = try TempHome()
        defer { home.remove() }
        var board = UsageBoard()
        record(&board, claudeAccount, remaining: 42)
        let summary = try single(content(board, claude: try claudeProfiles(home), chatgpt: [chatgptProfile("default")],
                                         hides: MenuBarToolPreferences(hidesClaudeCode: true, hidesChatGPT: true)))
        try expectEqual(summary, MenuBarSummary(profileName: "work", fiveHour: .remaining(42, tint: .yellow),
                                                tier: .max(multiplier: 20)))
        // 隐藏了 Claude Code、又没有 ChatGPT 默认档案：也显示 Claude Code
        try expectEqual(try single(content(board, claude: try claudeProfiles(home), chatgpt: [],
                                           hides: MenuBarToolPreferences(hidesClaudeCode: true))).tool, .claudeCode)
    }

    static func missingCurrentProfile() throws {
        let home = try TempHome()
        defer { home.remove() }
        var board = UsageBoard()
        record(&board, claudeAccount, remaining: 42)
        record(&board, chatgptAccount, remaining: 87)
        let rows = try lines(content(board, claude: try claudeProfiles(home), claudeCurrent: "gone",
                                     chatgpt: [chatgptProfile("default"), chatgptProfile("fresh", userID: nil)],
                                     chatgptCurrent: "fresh"))
        try expectEqual(rows.map { $0.quotaLine(resetText: "Reset") }, ["—", "—"])
        try expectEqual(rows.map(\.profileName), ["gone", "fresh"])
    }
}
