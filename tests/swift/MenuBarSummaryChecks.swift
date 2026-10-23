// ticket 07：菜单栏两行的内容。上一行当前档案名（后改为订阅等级，不知道时退回档案名），
// 下一行额度（ticket 11 接入前一律"—"）。

import Foundation

final class MenuBarSummaryChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("还没有额度数据时第二行显示—，有数据时显示剩余百分比", quotaLine),
            Check("已过重置时间时第二行显示已重置，不显示旧数字（ticket 12）", resetLine),
            Check("第二行的颜色与列表相同：severity、变灰；没有数字时不着色（ticket 12）", quotaTint),
            Check("第一行是当前档案记录里的名字", nameLineFollowsRecord),
            Check("第一行显示当前档案的订阅等级（凭据优先）；不知道时退回档案名", tierLine),
        ]
    }

    static func quotaLine() throws {
        try expectEqual(MenuBarSummary(profileName: "work").quotaLine(resetText: "Reset"), "—")
        try expectEqual(MenuBarSummary(profileName: "work", fiveHour: .remaining(42, tint: .plain))
            .quotaLine(resetText: "Reset"), "42%")
        try expectEqual(MenuBarSummary(profileName: "work", fiveHour: .remaining(0, tint: .severity(.critical)))
            .quotaLine(resetText: "Reset"), "0%")
    }

    static func resetLine() throws {
        try expectEqual(MenuBarSummary(profileName: "work", fiveHour: .resetPendingRefresh)
            .quotaLine(resetText: "已重置"), "已重置")
    }

    static func quotaTint() throws {
        try expectEqual(MenuBarSummary(profileName: "w", fiveHour: .remaining(9, tint: .severity(.warning))).quotaTint,
                        .severity(.warning))
        try expectEqual(MenuBarSummary(profileName: "w", fiveHour: .remaining(9, tint: .stale)).quotaTint, .stale)
        try expectEqual(MenuBarSummary(profileName: "w", fiveHour: .remaining(9, tint: .plain)).quotaTint, .plain)
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

    static func tierLine() throws {
        func profile(_ name: String, tier: SubscriptionTier?, credentialTier: SubscriptionTier? = nil,
                     loggedIn: Bool = true) -> Profile {
            let account = Account(accountUuid: "u-\(name)", email: "\(name)@example.com", organizationName: nil, tier: tier)
            return Profile(name: name, configDir: nil, claudeJSON: URL(fileURLWithPath: "/nonexistent/\(name).json"),
                           account: loggedIn ? .loggedIn(account) : .loggedOut,
                           login: LoginInfo(status: loggedIn ? .canRequestUsage : .notLoggedIn,
                                            subscriptionTier: credentialTier))
        }
        let profiles = [profile("max", tier: .max(multiplier: 5)),
                        profile("pro", tier: .max(multiplier: nil), credentialTier: .pro),
                        profile("unknown", tier: nil),
                        profile("fresh", tier: nil, loggedIn: false)]
        let board = UsageBoard()
        func tier(_ name: String) -> SubscriptionTier? {
            board.menuBarSummary(currentProfile: name, profiles: profiles, now: Date()).tier
        }
        try expectEqual(tier("max"), .max(multiplier: 5))
        try expectEqual(tier("pro"), .pro, "凭据里的订阅等级优先")
        try expectEqual(tier("unknown"), nil)
        try expectEqual(tier("fresh"), nil, "未登录")
        try expectEqual(tier("gone"), nil, "当前档案记录指向已不存在的档案")
        try expectEqual(MenuBarSummary(profileName: "w").tier, nil)
    }
}
