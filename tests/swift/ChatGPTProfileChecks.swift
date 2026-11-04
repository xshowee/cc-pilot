// chatgpt-profiles ticket 02：App 核心列出 ChatGPT 档案（ChatGPTProfileStore）。
// 档案来源、当前档案、auth.json 的只读解析（JWT 载荷、过期、未登录、API key、读不懂）、同一账号的判断，
// 以及 auth.json 里的令牌不出现在任何返回值、错误和输出里。

import Foundation

final class ChatGPTProfileChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("没有 ~/.codex 时没有 ChatGPT 档案（面板不显示这一段）", noDefaultMeansNoSection),
            Check("默认档案 ~/.codex 在最前，其他档案按字节序，与 ccp chatgpt ls 相同", listsLikeCcpChatgptLs),
            Check("名字不合规、保留名、文件都不是档案；指向目录的软链接是", ignoresNonProfileEntries),
            Check("当前档案读 ~/.codex-profiles/active，与 Claude 的记录互不影响", readsCurrentProfile),
            Check("从 id_token 读出邮箱、套餐、用户 ID，从 tokens.account_id 读出工作区 ID", parsesAccount),
            Check("access token 过期（含恰好到期）→ 待续期；没有 exp 按未过期", expiredAccessTokenNeedsRenewal),
            Check("没有 auth.json → 未登录", missingAuthIsNotLoggedIn),
            Check("auth_mode 为 apikey → API key，不读账号、不能请求额度", apiKeyMode),
            Check("没有 auth_mode 但有 ChatGPT 令牌时按 ChatGPT 登录处理", missingAuthModeWithTokens),
            Check("auth.json 读不懂或打不开 → 版本不兼容", unreadableAuthIsIncompatible),
            Check("同一用户 + 同一工作区才是同一账号；同一工作区的不同用户不是", marksSameAccount),
            Check("只有能请求额度时才给出令牌和工作区 ID", usageAuthorization),
            Check("auth.json 里的令牌不出现在返回值、错误和输出里", noTokenLeaks),
            Check("列出 ChatGPT 档案不创建、不修改任何文件", listingIsReadOnly),
        ]
    }

    static func store(_ home: TempHome) -> ChatGPTProfileStore {
        ChatGPTProfileStore(environment: home.environment)
    }

    static func noDefaultMeansNoSection() throws {
        let home = try TempHome()
        defer { home.remove() }
        try expectEqual(store(home).listProfiles(now: fixedNow).count, 0, "空主目录")
        try expect(!store(home).defaultProfileExists, "空主目录没有默认档案")
        // 只有 ~/.codex-profiles 下的档案、没有 ~/.codex 也不显示
        try home.makeCodexProfile("work", auth: chatgptAuth())
        try expectEqual(store(home).listProfiles(now: fixedNow).count, 0, "没有 ~/.codex")
        // ~/.codex 是文件不算
        try home.write(".codex", "x")
        try expectEqual(store(home).listProfiles(now: fixedNow).count, 0, "~/.codex 是文件")
    }

    static func listsLikeCcpChatgptLs() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        for name in ["zed", "Alpha", "beta", "1x", "a-b", "a_b", "a.b"] { try home.makeCodexProfile(name) }
        // Claude 的档案不是 ChatGPT 档案
        try home.makeProfileDir("claude-only")
        let expected = ["default", "1x", "Alpha", "a-b", "a.b", "a_b", "beta", "zed"]

        let profiles = store(home).listProfiles(now: fixedNow)
        try expectEqual(profiles.map(\.name), expected)
        try expect(store(home).defaultProfileExists, "有 ~/.codex")
        try expectEqual(profiles[0].codexHome, nil, "默认档案不设置 CODEX_HOME")
        try expectEqual(profiles[0].directory, home.url.path + "/.codex")
        try expect(profiles[0].isDefault, "第一个是默认档案")
        try expectEqual(profiles[2].codexHome, home.url.path + "/.codex-profiles/Alpha")
        try expectEqual(profiles[2].directory, home.url.path + "/.codex-profiles/Alpha")

        let ccp = repoRoot.appendingPathComponent("shell/bin/ccp").path
        for alias in ["chatgpt", "codex"] {
            let result = try ShellRun.run(home, [ccp, alias, "ls"])
            try expectEqual(result.status, 0, "ccp \(alias) ls 的退出码（stderr：\(result.err)）")
            try expectEqual(result.out.split(separator: "\n").map { String($0.dropFirst(2)) }, expected,
                            "ccp \(alias) ls 的顺序")
        }
    }

    static func ignoresNonProfileEntries() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        try home.makeCodexProfile("ok.1_a-b")
        try home.write(".codex-profiles/active", "ok.1_a-b\n")
        try home.write(".codex-profiles/.active.Ab12Cd", "x\n")
        try home.write(".codex-profiles/notes", "x\n")
        for bad in ["-bad", ".hidden", "bad name", "default"] { try home.makeCodexProfile(bad) }
        let target = home.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.codexProfilesRoot.appendingPathComponent("linked"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(
            at: home.codexProfilesRoot.appendingPathComponent("dangling"),
            withDestinationURL: home.root.appendingPathComponent("missing"))

        try expectEqual(store(home).listProfiles(now: fixedNow).map(\.name), ["default", "linked", "ok.1_a-b"])
    }

    static func readsCurrentProfile() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        try home.makeCodexProfile("work")
        try expectEqual(store(home).currentProfileName(), "default", "没有记录")
        try home.write(".claude-profiles/active", "personal\n")
        try expectEqual(store(home).currentProfileName(), "default", "Claude 的记录不影响 ChatGPT")
        try home.write(".codex-profiles/active", "  work \r\nsecond line\n")
        try expectEqual(store(home).currentProfileName(), "work", "只取第一行、去掉首尾空白")
        try expectEqual(CurrentProfileRecord(environment: home.environment).currentName(), "personal",
                        "ChatGPT 的记录不影响 Claude")
        try home.write(".codex-profiles/active", "\n")
        try expectEqual(store(home).currentProfileName(), "default", "空记录")
        try home.write(".codex-profiles/active", "gone\n")
        try expectEqual(store(home).currentProfileName(), "gone", "不存在的档案名原样返回")
    }

    static func parsesAccount() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault(auth: chatgptAuth(email: "me@example.com", plan: "pro",
                                                    userID: "user-AAA", workspaceID: "ws-team"))
        let p = try unwrap(store(home).listProfiles(now: fixedNow).first)
        try expectEqual(p.status, .canRequestUsage)
        let account = try unwrap(p.account, "应读出账号")
        try expectEqual(account.email, "me@example.com")
        try expectEqual(account.planType, "pro")
        try expectEqual(account.userID, "user-AAA")
        try expectEqual(account.workspaceID, "ws-team")
        try expectEqual(account.key, ChatGPTAccountKey(userID: "user-AAA", workspaceID: "ws-team"))
        try expect(p.status.allowsUsageRequest, "可以请求额度")
    }

    static func expiredAccessTokenNeedsRenewal() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault(auth: chatgptAuth(accessExp: -60))
        try home.makeCodexProfile("edge", auth: chatgptAuth(accessExp: 0))
        try home.makeCodexProfile("noexp", auth: chatgptAuth(accessExp: nil))
        try home.makeCodexProfile("fresh", auth: chatgptAuth(accessExp: 1))
        let byName = Dictionary(uniqueKeysWithValues: store(home).listProfiles(now: fixedNow).map { ($0.name, $0) })
        try expectEqual(byName["default"]?.status, .needsRenewal, "已过期")
        try expectEqual(byName["default"]?.account?.email, "me@example.com", "待续期时仍显示账号")
        try expect(byName["default"]?.status.allowsUsageRequest == false, "待续期不能请求额度")
        try expectEqual(byName["edge"]?.status, .needsRenewal, "恰好到期算已过期")
        try expectEqual(byName["noexp"]?.status, .canRequestUsage, "没有 exp 按未过期")
        try expectEqual(byName["fresh"]?.status, .canRequestUsage, "还有 1 秒")
    }

    static func missingAuthIsNotLoggedIn() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        try home.makeCodexProfile("fresh")
        for p in store(home).listProfiles(now: fixedNow) {
            try expectEqual(p.status, .notLoggedIn, p.name)
            try expectEqual(p.account, nil, p.name)
        }
    }

    static func apiKeyMode() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault(auth: apiKeyAuth())
        // auth_mode 为 apikey 时，即使还留着 ChatGPT 令牌也按 API key 处理
        var mixed = chatgptAuth()
        mixed["auth_mode"] = "apikey"
        try home.makeCodexProfile("mixed", auth: mixed)
        for p in store(home).listProfiles(now: fixedNow) {
            try expectEqual(p.status, .apiKey, p.name)
            try expectEqual(p.account, nil, p.name)
            try expect(!p.status.allowsUsageRequest, "API key 不参与额度")
        }
    }

    static func missingAuthModeWithTokens() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault(auth: chatgptAuth(authMode: nil))
        let p = try unwrap(store(home).listProfiles(now: fixedNow).first)
        try expectEqual(p.status, .canRequestUsage)
        try expectEqual(p.account?.email, "me@example.com")
    }

    static func unreadableAuthIsIncompatible() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        try home.write(".codex/auth.json", "not json")
        try home.makeCodexProfile("array", auth: nil)
        try home.write(".codex-profiles/array/auth.json", "[]")
        var noTokens = chatgptAuth()
        noTokens["tokens"] = nil
        try home.makeCodexProfile("notokens", auth: noTokens)
        var badID = chatgptAuth()
        badID["tokens"] = ["id_token": "garbage", "access_token": "x.y.z", "account_id": "ws"]
        try home.makeCodexProfile("badjwt", auth: badID)
        try home.makeCodexProfile("unknownmode", auth: chatgptAuth(authMode: "something-new"))
        try home.makeCodexProfile("isdir")
        try FileManager.default.createDirectory(
            at: home.codexProfilesRoot.appendingPathComponent("isdir/auth.json"), withIntermediateDirectories: true)

        let byName = Dictionary(uniqueKeysWithValues: store(home).listProfiles(now: fixedNow).map { ($0.name, $0) })
        for name in ["default", "array", "notokens", "badjwt", "unknownmode"] {
            try expectEqual(byName[name]?.status, .incompatible(.malformed), name)
            try expectEqual(byName[name]?.account, nil, name)
        }
        try expectEqual(byName["isdir"]?.status, .incompatible(.unreadableFile), "auth.json 是目录")
    }

    static func marksSameAccount() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault(auth: chatgptAuth(email: "a@corp.example", userID: "user-A", workspaceID: "ws-team"))
        // 同一用户、同一工作区：同一账号（邮箱大小写不同也不影响）
        try home.makeCodexProfile("again", auth: chatgptAuth(email: "A@corp.example", userID: "user-A",
                                                             workspaceID: "ws-team", accessExp: -10))
        // 同一 Team 工作区的另一个用户：account_id 相同，但不是同一账号
        try home.makeCodexProfile("colleague", auth: chatgptAuth(email: "b@corp.example", userID: "user-B",
                                                                 workspaceID: "ws-team"))
        // 同一用户的个人工作区：不是同一账号
        try home.makeCodexProfile("personal", auth: chatgptAuth(email: "a@corp.example", userID: "user-A",
                                                                workspaceID: "ws-personal"))
        try home.makeCodexProfile("keyonly", auth: apiKeyAuth())
        try home.makeCodexProfile("empty")

        let byName = Dictionary(uniqueKeysWithValues: store(home).listProfiles(now: fixedNow).map { ($0.name, $0) })
        try expectEqual(byName["default"]?.sameAccountAs, ["again"])
        try expectEqual(byName["again"]?.sameAccountAs, ["default"])
        try expectEqual(byName["colleague"]?.sameAccountAs, [], "同一工作区的不同用户不是同一账号")
        try expectEqual(byName["personal"]?.sameAccountAs, [], "同一用户的不同工作区不是同一账号")
        try expectEqual(byName["keyonly"]?.sameAccountAs, [])
        try expectEqual(byName["empty"]?.sameAccountAs, [])
    }

    static func usageAuthorization() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault(auth: chatgptAuth(workspaceID: "ws-9"))
        try home.makeCodexProfile("expired", auth: chatgptAuth(accessExp: -1))
        try home.makeCodexProfile("key", auth: apiKeyAuth())
        try home.makeCodexProfile("empty")
        let s = store(home)
        let byName = Dictionary(uniqueKeysWithValues: s.listProfiles(now: fixedNow).map { ($0.name, $0) })

        guard case .granted(let credential) = s.usageAuthorization(for: try unwrap(byName["default"]), now: fixedNow)
        else { throw CheckFailure(description: "默认档案应能请求额度") }
        try expect(credential.accessToken.hasSuffix("." + ChatGPTSentinel.accessSignature), "给出的应是 access token")
        try expectEqual(credential.accountID, "ws-9")

        for (name, status) in [("expired", ChatGPTLoginStatus.needsRenewal), ("key", .apiKey), ("empty", .notLoggedIn)] {
            guard case .denied(let reason) = s.usageAuthorization(for: try unwrap(byName[name]), now: fixedNow)
            else { throw CheckFailure(description: "\(name) 不应拿到令牌") }
            try expectEqual(reason, status, name)
        }
    }

    static func noTokenLeaks() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault(auth: chatgptAuth())
        try home.makeCodexProfile("expired", auth: chatgptAuth(accessExp: -1))
        try home.makeCodexProfile("key", auth: apiKeyAuth())
        try home.makeCodexProfile("garbled")
        try home.write(".codex-profiles/garbled/auth.json",
                       "{oops \(ChatGPTSentinel.refreshToken) \(ChatGPTSentinel.accessSignature)")
        var weird = chatgptAuth()
        weird["tokens"] = ["id_token": ChatGPTSentinel.idSignature, "access_token": ChatGPTSentinel.accessSignature]
        try home.makeCodexProfile("weird", auth: weird)

        var texts: [String] = []
        var granted = 0
        let log = home.root.appendingPathComponent("captured-output.log")
        try CredentialSafetyChecks.capturingOutput(to: log) {
            let s = store(home)
            let profiles = s.listProfiles(now: fixedNow)
            texts += CredentialSafetyChecks.renderings(profiles)
            for p in profiles {
                let auth = s.usageAuthorization(for: p, now: fixedNow)
                if case .granted(let credential) = auth {
                    granted += 1
                    texts += CredentialSafetyChecks.renderings(credential)
                }
                texts += CredentialSafetyChecks.renderings(p) + CredentialSafetyChecks.renderings(auth)
                    + CredentialSafetyChecks.renderings(p.status)
            }
        }
        try expectEqual(granted, 1, "确实读到了令牌（泄露检查才有意义）")
        let output = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        for text in texts + [output] {
            for sentinel in ChatGPTSentinel.all {
                try expect(!text.contains(sentinel), "出现了令牌 \(sentinel)：\(text.prefix(300))")
            }
        }
    }

    static func listingIsReadOnly() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault(auth: chatgptAuth())
        try home.makeCodexProfile("work", auth: chatgptAuth(accessExp: -1))
        try home.makeCodexProfile("empty")
        try home.write(".codex-profiles/active", "work\n")
        let before = try CredentialSafetyChecks.snapshot(home.root)
        let entriesBefore = try FileManager.default.subpathsOfDirectory(atPath: home.root.path).sorted()
        let s = store(home)
        for p in s.listProfiles(now: fixedNow) { _ = s.usageAuthorization(for: p, now: fixedNow) }
        _ = s.currentProfileName()
        try expectEqual(try CredentialSafetyChecks.snapshot(home.root), before)
        try expectEqual(try FileManager.default.subpathsOfDirectory(atPath: home.root.path).sorted(), entriesBefore)
    }
}
