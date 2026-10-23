// ticket 10：登录状态的五种判定，以及额度请求能否拿到凭据（ticket 11 据此决定是否发请求）。
// 期望值来自 spec "登录状态的判定"。

import Foundation

final class LoginStatusChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check(".claude.json 没有账号资料：未登录", notLoggedIn),
            Check("accessToken 已过期、refreshToken 有效：待续期", needsRenewal),
            Check("refreshToken 为空、缺失或已过期：需重新登录（即使 accessToken 还有效）", needsReLogin),
            Check("scopes 缺少 user:profile 或 user:inference：不支持额度显示", usageUnsupported),
            Check("其余情况：可以请求额度（过期时间缺失按未过期处理）", canRequestUsage),
            Check("只有可以请求额度时才拿得到令牌；待续期、需重新登录等一律拿不到", authorization),
            Check("订阅等级以凭据的 subscriptionType 为准，认不出时退回 .claude.json 的推断", subscriptionTier),
        ]
    }

    /// 准备若干个已登录的档案，每个档案一份凭据 JSON，返回 名字 → 状态
    static func statuses(_ cases: [(String, String)]) throws -> [String: LoginStatus] {
        let home = try TempHome()
        defer { home.remove() }
        for (i, (name, json)) in cases.enumerated() {
            let svc = try home.makeLoggedInProfile(name, uuid: "u\(i)")
            try home.keychainItem(service: svc, json)
        }
        return home.profilesWithLogin().compactMapValues { $0.login?.status }
    }

    static func expectStatuses(_ expected: LoginStatus, _ cases: [(String, String)],
                               file: StaticString = #fileID, line: UInt = #line) throws {
        let got = try statuses(cases)
        for (name, _) in cases {
            try expectEqual(got[name], expected, name, file: file, line: line)
        }
    }

    static func notLoggedIn() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfile("work", config: ["oauthAccount": NSNull(), "projects": [String: Any]()])
        // 钥匙串里有凭据也不算登录：以 .claude.json 的账号资料为准
        try home.keychainItem(service: KeychainServiceName.forConfigDir(home.url.path + "/.claude-profiles/work"),
                              credentialJSON())
        try home.keychainItem(service: "Claude Code-credentials", credentialJSON())
        let profiles = home.profilesWithLogin()
        try expectEqual(profiles["default"]?.login?.status, .notLoggedIn)
        try expectEqual(profiles["work"]?.login?.status, .notLoggedIn)
    }

    static func needsRenewal() throws {
        try expectStatuses(.needsRenewal, [
            ("expired", credentialJSON(expiresAt: ms(-60))),
            ("justnow", credentialJSON(expiresAt: ms(0))),
            ("refreshfuture", credentialJSON(expiresAt: ms(-60), refreshExpiresAt: ms(86_400))),
            ("noaccess", credentialJSON(access: nil)),
            ("emptyaccess", credentialJSON(access: "")),
            // 按 spec 的顺序先判断过期，再判断 scopes：scopes 不完整但 accessToken 已过期，仍是待续期
            ("expiredbadscopes", credentialJSON(expiresAt: ms(-60), scopes: ["user:inference"])),
        ])
    }

    static func needsReLogin() throws {
        try expectStatuses(.needsReLogin, [
            ("empty", credentialJSON(refresh: "")),
            ("missing", credentialJSON(refresh: nil)),
            ("nulled", credentialJSON(refresh: nil, extra: ["refreshToken": NSNull()])),
            ("expired", credentialJSON(refreshExpiresAt: ms(-1))),
            ("bothexpired", credentialJSON(expiresAt: ms(-60), refreshExpiresAt: ms(-60))),
            ("emptyandexpired", credentialJSON(expiresAt: ms(-60), refresh: "")),
        ])
    }

    static func usageUnsupported() throws {
        try expectStatuses(.usageUnsupported, [
            ("noprofile", credentialJSON(scopes: ["user:inference"])),
            ("noinference", credentialJSON(scopes: ["user:profile", "user:sessions:claude_code"])),
            ("empty", credentialJSON(scopes: [])),
            ("absent", credentialJSON(scopes: nil)),
            ("notarray", credentialJSON(scopes: nil, extra: ["scopes": "user:profile user:inference"])),
        ])
    }

    static func canRequestUsage() throws {
        try expectStatuses(.canRequestUsage, [
            ("full", credentialJSON()),
            ("minimal", credentialJSON(scopes: ["user:profile", "user:inference"])),
            ("noexpiry", credentialJSON(expiresAt: nil)),
            ("refreshvalid", credentialJSON(refreshExpiresAt: ms(60))),
            ("nosubscription", credentialJSON(subscriptionType: nil)),
            ("stringexpiry", credentialJSON(expiresAt: nil, extra: ["expiresAt": "soon"])),
        ])
    }

    static func authorization() throws {
        let home = try TempHome()
        defer { home.remove() }
        let cases: [(String, String?, LoginStatus)] = [
            ("ok", credentialJSON(), .canRequestUsage),
            ("renew", credentialJSON(expiresAt: ms(-60)), .needsRenewal),
            ("relogin", credentialJSON(refresh: ""), .needsReLogin),
            ("unsupported", credentialJSON(scopes: ["user:inference"]), .usageUnsupported),
            ("missing", nil, .incompatible(.itemNotFound)),
        ]
        for (i, (name, json, _)) in cases.enumerated() {
            let svc = try home.makeLoggedInProfile(name, uuid: "u\(i)")
            if let json { try home.keychainItem(service: svc, json) }
        }
        try home.makeProfileDir("fresh")

        let checker = LoginChecker(environment: home.environment)
        let profiles = Dictionary(uniqueKeysWithValues:
            ProfileStore(environment: home.environment).listProfiles().map { ($0.name, $0) })
        for (name, _, expected) in cases + [("fresh", nil, .notLoggedIn)] {
            guard let profile = profiles[name] else { throw CheckFailure(description: "缺少档案 \(name)") }
            let auth = checker.usageAuthorization(for: profile, now: fixedNow)
            switch auth {
            case .granted(let credential):
                try expectEqual(expected, .canRequestUsage, "\(name) 不应拿到令牌")
                try expectEqual(credential.accessToken, Sentinel.accessToken, name)
            case .denied(let status):
                try expect(expected != .canRequestUsage, "\(name) 应拿到令牌")
                try expectEqual(status, expected, name)
                try expect(!status.allowsUsageRequest, "\(name) 的状态不应允许请求")
            }
        }
        try expect(LoginStatus.canRequestUsage.allowsUsageRequest, "可以请求额度时应允许请求")
        for s: LoginStatus in [.notLoggedIn, .needsRenewal, .needsReLogin, .usageUnsupported,
                               .incompatible(.emptyItem), .accountUnreadable] {
            try expect(!s.allowsUsageRequest, "\(s) 不应允许请求")
        }
    }

    static func subscriptionTier() throws {
        let home = try TempHome()
        defer { home.remove() }
        // (档案, .claude.json 的 organizationType, 限速等级, 凭据的 subscriptionType, 凭据的 rateLimitTier, 期望)
        let cases: [(String, String?, String?, String?, String?, SubscriptionTier?)] = [
            ("credmax", nil, nil, "max", "default_claude_max_5x", .max(multiplier: 5)),
            ("credmaxnotier", nil, nil, "max", nil, .max(multiplier: nil)),
            ("credmaxorgtier", "claude_max", "default_claude_max_20x", "max", nil, .max(multiplier: 20)),
            ("credwins", "claude_team", nil, "pro", nil, .pro),
            ("credteam", nil, nil, "team", nil, .team),
            ("credenterprise", nil, nil, "enterprise", nil, .enterprise),
            ("credunknown", "claude_pro", nil, "galaxy", nil, .pro),
            ("crednone", "claude_max", "default_claude_max_20x", nil, nil, .max(multiplier: 20)),
            ("nothing", nil, nil, nil, nil, nil),
        ]
        for (i, c) in cases.enumerated() {
            let svc = try home.makeLoggedInProfile(c.0, uuid: "u\(i)", orgType: c.1, rateLimitTier: c.2)
            var extra: [String: Any] = [:]
            if let t = c.4 { extra["rateLimitTier"] = t }
            try home.keychainItem(service: svc, credentialJSON(subscriptionType: c.3, extra: extra))
        }
        try home.makeLoggedInProfile("nokeychain", uuid: "u-x", orgType: "claude_pro")
        let profiles = home.profilesWithLogin()
        for c in cases {
            try expectEqual(profiles[c.0]?.displayTier, c.5, c.0)
        }
        // 读不到凭据时照样显示 .claude.json 推断的等级
        try expectEqual(profiles["nokeychain"]?.displayTier, .pro, "nokeychain")
    }
}
