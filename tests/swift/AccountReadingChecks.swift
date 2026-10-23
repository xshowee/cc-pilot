// ticket 06：从各档案的 .claude.json 读取账号资料（通过 ProfileStore.listProfiles 观察）。

import Foundation

final class AccountReadingChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("某个档案的 .claude.json 损坏时显示为无法读取，不影响其他档案", corruptConfigIsIsolated),
            Check("没有账号资料的各种形式都算未登录", variantsOfLoggedOut),
            Check("结构不认识的 .claude.json 显示为无法读取", unrecognizedStructures),
            Check("读不了的 .claude.json 显示为无法读取", unreadableFiles),
            Check("账号资料字段缺失、为 null 或类型不对时照样显示其余字段", tolerantFields),
            Check("订阅等级从 organizationType 推断，不认识的原样保留", subscriptionTierInference),
        ]
    }

    private static func accounts(_ home: TempHome) -> [String: AccountState] {
        Dictionary(uniqueKeysWithValues:
            ProfileStore(environment: home.environment).listProfiles().map { ($0.name, $0.account) })
    }

    static func corruptConfigIsIsolated() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".claude.json", "{\"oauthAccount\": {\"emailAddress\": ")   // 写到一半
        try home.makeProfileDir("broken")
        try home.write(".claude-profiles/broken/.claude.json", "not json at all")
        try home.makeProfile("good", config: claudeConfig(uuid: "u1", email: "good@example.com"))

        let states = accounts(home)
        try expectEqual(states["default"], .unreadable(.malformed))
        try expectEqual(states["broken"], .unreadable(.malformed))
        try expectEqual(states["good"]?.account?.email, "good@example.com")
    }

    static func variantsOfLoggedOut() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("missing")                                     // 没有 .claude.json
        try home.makeProfile("nokey", config: ["mcpServers": [String: Any](), "projects": [String: Any]()])
        try home.makeProfile("null", config: ["oauthAccount": NSNull()])
        try home.makeProfile("empty", config: ["oauthAccount": [String: Any]()])
        try home.makeProfile("blank", config: ["oauthAccount": ["accountUuid": "", "emailAddress": "  "]])

        let states = accounts(home)
        for name in ["default", "missing", "nokey", "null", "empty", "blank"] {
            try expectEqual(states[name], .loggedOut, name)
        }
    }

    static func unrecognizedStructures() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("array")
        try home.write(".claude-profiles/array/.claude.json", "[1, 2]")
        try home.makeProfile("stringacct", config: ["oauthAccount": "someone@example.com"])

        let states = accounts(home)
        try expectEqual(states["array"], .unreadable(.malformed))
        try expectEqual(states["stringacct"], .unreadable(.malformed))
    }

    static func unreadableFiles() throws {
        let home = try TempHome()
        defer { home.remove() }
        // .claude.json 是个目录
        try FileManager.default.createDirectory(
            at: home.profilesRoot.appendingPathComponent("dir/.claude.json"), withIntermediateDirectories: true)
        // 没有读权限
        try home.makeProfile("noperm", config: claudeConfig(uuid: "u", email: "x@example.com"))
        let noperm = home.profilesRoot.appendingPathComponent("noperm/.claude.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: noperm)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: noperm) }

        let states = accounts(home)
        try expectEqual(states["dir"], .unreadable(.unreadableFile))
        try expectEqual(states["noperm"], .unreadable(.unreadableFile))
    }

    static func tolerantFields() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfile("emailonly", config: ["oauthAccount": [
            "emailAddress": "e@example.com", "accountUuid": NSNull(), "organizationName": 42,
            "organizationType": NSNull()]])
        try home.makeProfile("uuidonly", config: ["oauthAccount": ["accountUuid": "u-2"]])

        let states = accounts(home)
        try expectEqual(states["emailonly"], .loggedIn(Account(
            accountUuid: nil, email: "e@example.com", organizationName: nil, tier: nil)))
        try expectEqual(states["uuidonly"], .loggedIn(Account(
            accountUuid: "u-2", email: nil, organizationName: nil, tier: nil)))
    }

    static func subscriptionTierInference() throws {
        let home = try TempHome()
        defer { home.remove() }
        let cases: [(String, String?, String?, SubscriptionTier?)] = [
            ("pro", "claude_pro", "default_claude_ai", .pro),
            ("max5", "claude_max", "default_claude_max_5x", .max(multiplier: 5)),
            ("max20", "claude_max", "default_claude_max_20x", .max(multiplier: 20)),
            ("maxunknown", "claude_max", "something_else", .max(multiplier: nil)),
            ("maxnotier", "claude_max", nil, .max(multiplier: nil)),
            ("team", "claude_team", nil, .team),
            ("enterprise", "claude_enterprise", nil, .enterprise),
            ("future", "claude_galaxy", nil, .other("claude_galaxy")),
            ("none", nil, "default_claude_max_20x", nil),
            ("blank", "", nil, nil),
            ("spaces", "  ", nil, nil),
        ]
        for (name, type, tier, _) in cases {
            try home.makeProfile(name, config: claudeConfig(
                uuid: "u-\(name)", email: "\(name)@example.com", orgType: type, rateLimitTier: tier))
        }
        let states = accounts(home)
        for (name, _, _, expected) in cases {
            try expect(states[name]?.account != nil, "\(name) 应为已登录")
            try expectEqual(states[name]?.account?.tier, expected, name)
        }
    }
}
