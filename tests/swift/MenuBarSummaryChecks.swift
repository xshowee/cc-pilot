// ticket 07：菜单栏两行的内容。上一行当前档案的订阅等级，不知道时是档案名；下一行额度。

import Foundation

final class MenuBarSummaryChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("还没有额度数据时第二行显示—，有数据时显示剩余百分比", quotaLine),
            Check("已过重置时间时第二行显示已重置，不显示旧数字（ticket 12）", resetLine),
            Check("第二行的颜色与列表相同：阈值颜色、变灰；没有数字时不着色（ticket 12）", quotaTint),
            Check("档案名来自当前档案记录", nameLineFollowsRecord),
            Check("第一行显示订阅等级，不知道时是档案名", titleLine),
            Check("订阅等级取自当前档案的 displayTier", tierFollowsProfile),
        ]
    }

    static func quotaLine() throws {
        try expectEqual(MenuBarSummary(profileName: "work").quotaLine(resetText: "Reset"), "—")
        try expectEqual(MenuBarSummary(profileName: "work", fiveHour: .remaining(42, tint: .yellow))
            .quotaLine(resetText: "Reset"), "42%")
        try expectEqual(MenuBarSummary(profileName: "work", fiveHour: .remaining(0, tint: .red))
            .quotaLine(resetText: "Reset"), "0%")
    }

    static func resetLine() throws {
        try expectEqual(MenuBarSummary(profileName: "work", fiveHour: .resetPendingRefresh)
            .quotaLine(resetText: "已重置"), "已重置")
    }

    static func quotaTint() throws {
        try expectEqual(MenuBarSummary(profileName: "w", fiveHour: .remaining(9, tint: .red)).quotaTint, .red)
        try expectEqual(MenuBarSummary(profileName: "w", fiveHour: .remaining(9, tint: .stale)).quotaTint, .stale)
        try expectEqual(MenuBarSummary(profileName: "w", fiveHour: .resetPendingRefresh).quotaTint, .plain)
        try expectEqual(MenuBarSummary(profileName: "w").quotaTint, .plain)
    }

    static func nameLineFollowsRecord() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        let record = CurrentProfileRecord(environment: home.environment)

        try expectEqual(MenuBarSummary(record: record).profileName, "default")
        try record.switchTo("work")
        try expectEqual(MenuBarSummary(record: record).profileName, "work")
        // 在终端里用 ccp use 切换（这里直接按 ccp use 的格式写记录）
        try home.write(".claude-profiles/active", "default\n")
        try expectEqual(MenuBarSummary(record: record), MenuBarSummary(profileName: "default"))
    }

    static func titleLine() throws {
        let name: (SubscriptionTier) -> String = { $0 == .max(multiplier: 5) ? "Max 5x" : "?" }
        try expectEqual(MenuBarSummary(profileName: "work", tier: .max(multiplier: 5)).titleLine(tierName: name), "Max 5x")
        try expectEqual(MenuBarSummary(profileName: "work").titleLine(tierName: name), "work")
    }

    static func tierFollowsProfile() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeLoggedInProfile("max", orgType: "claude_max", rateLimitTier: "default_claude_max_20x")
        // .claude.json 推断为 Max，凭据说是 Pro：取凭据（displayTier），不取账号等级
        try home.keychainItem(service: home.makeLoggedInProfile("pro", uuid: "u-pro", orgType: "claude_max"),
                              credentialJSON(subscriptionType: "pro"))
        try home.makeLoggedInProfile("unknown", uuid: "u-unknown")
        try home.makeProfileDir("fresh")
        let profiles = Array(home.profilesWithLogin().values)
        func tier(_ name: String) -> SubscriptionTier? {
            UsageBoard().menuBarSummary(currentProfile: name, profiles: profiles, now: fixedNow).tier
        }
        try expectEqual(tier("max"), .max(multiplier: 20))
        try expectEqual(tier("pro"), .pro, "凭据里的订阅等级优先")
        try expectEqual(tier("unknown"), nil, "已登录但不知道订阅等级")
        try expectEqual(tier("fresh"), nil, "未登录")
        try expectEqual(tier("gone"), nil, "当前档案记录指向已不存在的档案")
    }
}
