// ticket 10：通过 security 读取每个档案的凭据（假 security 按测试准备的内容作答）。
// 观察点：LoginChecker 给出的登录状态，以及假 security 记录的调用参数。

import Foundation

final class CredentialReadChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("security 返回 JSON 原文：可以请求额度", plainJSON),
            Check("security 返回十六进制（小写或大写）：解码后照常判定", hexOutput),
            Check("默认档案和普通档案各自按自己的 service 名查询", queriesOwnService),
            Check("匹配到多条时优先取 account 等于当前用户名的那条", prefersCurrentUser),
            Check("没有当前用户名的那条时取第一条（例如 account 为 root）", fallsBackToFirstMatch),
            Check("当前用户名的那条为空时，改取第一条", emptyUserItemFallsBack),
            Check("已登录但钥匙串项不存在：版本不兼容", missingItem),
            Check("已登录但钥匙串项为空：版本不兼容", emptyItem),
            Check("内容既不是 JSON 也不是十六进制 JSON：格式无法识别，按版本不兼容处理", unrecognizedContent),
            Check("security 以其他退出码失败（如拒绝授权）：版本不兼容，不再重试", securityFails),
            Check("security 迟迟不结束（出现授权弹窗）：超时后按版本不兼容处理", securityHangs),
            Check("未登录、账号资料读不出的档案不查询钥匙串", noQueryWithoutAccount),
        ]
    }

    static func plainJSON() throws {
        let home = try TempHome()
        defer { home.remove() }
        let svc = try home.makeLoggedInProfile("work")
        try home.keychainItem(service: svc, credentialJSON())
        try expectEqual(home.loginStatus("work"), .canRequestUsage)
    }

    static func hexOutput() throws {
        let home = try TempHome()
        defer { home.remove() }
        // 含非 ASCII 字符的凭据：真的 security 会输出十六进制
        let json = credentialJSON(extra: ["note": "名字 é"])
        let lower = try home.makeLoggedInProfile("lower", uuid: "u1")
        let upper = try home.makeLoggedInProfile("upper", uuid: "u2")
        try home.keychainItem(service: lower, hexEncoded(json))
        try home.keychainItem(service: upper, hexEncoded(json, uppercase: true))
        let profiles = home.profilesWithLogin()
        try expectEqual(profiles["lower"]?.login?.status, .canRequestUsage, "小写十六进制")
        try expectEqual(profiles["upper"]?.login?.status, .canRequestUsage, "大写十六进制")

        // 十六进制解出来的内容也要真正参与判定：过期的长期凭据 → 需重新登录
        let expired = try home.makeLoggedInProfile("expired", uuid: "u3")
        try home.keychainItem(service: expired, hexEncoded(credentialJSON(refresh: "", extra: ["n": "值"])))
        try expectEqual(home.loginStatus("expired"), .needsReLogin)
    }

    static func queriesOwnService() throws {
        let home = try TempHome()
        defer { home.remove() }
        let defaultSvc = try home.makeLoggedInProfile("default", uuid: "u1")
        let workSvc = try home.makeLoggedInProfile("work", uuid: "u2")
        try home.keychainItem(service: defaultSvc, credentialJSON())
        // work 的钥匙串项故意放一份"需重新登录"的凭据，确认两者没有串
        try home.keychainItem(service: workSvc, credentialJSON(refresh: nil))
        let profiles = home.profilesWithLogin()
        try expectEqual(profiles["default"]?.login?.status, .canRequestUsage)
        try expectEqual(profiles["work"]?.login?.status, .needsReLogin)

        let services = Set(try home.securityCalls().compactMap { args in
            args.firstIndex(of: "-s").map { args[$0 + 1] }
        })
        try expectEqual(services, ["Claude Code-credentials", workSvc])
        try expect(workSvc.hasPrefix("Claude Code-credentials-") && workSvc.count == 32, "work 的 service 名：\(workSvc)")
    }

    static func prefersCurrentUser() throws {
        let home = try TempHome()
        defer { home.remove() }
        let svc = try home.makeLoggedInProfile("work")
        // 假 security 不带 -a 时取文件名排序的第一条，root 排在 tester 前面
        try home.keychainItem(service: svc, account: "root", credentialJSON(refresh: ""))
        try home.keychainItem(service: svc, account: TempHome.userName, credentialJSON())
        try expectEqual(home.loginStatus("work"), .canRequestUsage)

        let calls = try home.securityCalls()
        try expectEqual(calls.first, ["find-generic-password", "-s", svc, "-a", TempHome.userName, "-w"])
        try expectEqual(calls.count, 1, "找到当前用户名的那条后不应再查询")
    }

    static func fallsBackToFirstMatch() throws {
        let home = try TempHome()
        defer { home.remove() }
        let svc = try home.makeLoggedInProfile("default")
        try home.keychainItem(service: svc, account: "root", credentialJSON())
        try home.keychainItem(service: svc, account: "someone", credentialJSON(refresh: ""))
        try expectEqual(home.loginStatus("default"), .canRequestUsage)
        try expectEqual(try home.securityCalls(), [
            ["find-generic-password", "-s", svc, "-a", TempHome.userName, "-w"],
            ["find-generic-password", "-s", svc, "-w"],
        ])
    }

    static func emptyUserItemFallsBack() throws {
        let home = try TempHome()
        defer { home.remove() }
        let svc = try home.makeLoggedInProfile("work")
        try home.keychainItem(service: svc, account: "root", credentialJSON())
        try home.keychainItem(service: svc, account: TempHome.userName, "")
        try expectEqual(home.loginStatus("work"), .canRequestUsage)
    }

    static func missingItem() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeLoggedInProfile("default", uuid: "u1")
        let workSvc = try home.makeLoggedInProfile("work", uuid: "u2")
        // 别的 service 有凭据，不能被当成 work 的
        try home.keychainItem(service: workSvc + "x", credentialJSON())
        let profiles = home.profilesWithLogin()
        try expectEqual(profiles["default"]?.login?.status, .incompatible(.itemNotFound))
        try expectEqual(profiles["work"]?.login?.status, .incompatible(.itemNotFound))
    }

    static func emptyItem() throws {
        let home = try TempHome()
        defer { home.remove() }
        let svc = try home.makeLoggedInProfile("work")
        try home.keychainItem(service: svc, account: "root", "")
        try expectEqual(home.loginStatus("work"), .incompatible(.emptyItem))

        // 只有空白（真的 security 对空密码只输出一个换行）
        try home.keychainItem(service: svc, account: "root", "\n")
        try expectEqual(home.loginStatus("work"), .incompatible(.emptyItem))
    }

    static func unrecognizedContent() throws {
        let home = try TempHome()
        defer { home.remove() }
        let cases: [(String, String)] = [
            ("garbage", "not a credential"),
            ("badhex", "7b22zz"),
            ("oddhex", "7b2"),
            ("hexnotjson", hexEncoded("名字不是 JSON")),
            ("array", "[1,2]"),
            ("nooauth", #"{"somethingElse":{}}"#),
            ("oauthstring", #"{"claudeAiOauth":"x"}"#),
        ]
        for (i, (name, content)) in cases.enumerated() {
            let svc = try home.makeLoggedInProfile(name, uuid: "u\(i)")
            try home.keychainItem(service: svc, content)
        }
        let profiles = home.profilesWithLogin()
        for (name, _) in cases {
            try expectEqual(profiles[name]?.login?.status, .incompatible(.unrecognizedFormat), name)
        }
    }

    static func securityFails() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeLoggedInProfile("work")
        let log = home.root.appendingPathComponent("failing-calls")
        var env = home.environment
        env.security = try home.script("security-denied", """
            print -r -- "$*" >> \(shellQuoted(log.path))
            print -u2 -r -- "security: SecKeychainSearchCopyNext: User interaction is not allowed."
            exit 51
            """)
        try expectEqual(home.loginStatus("work", env), .incompatible(.readFailed(exitCode: 51)))
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        try expectEqual(calls.count, 1, "读取失败后不应再次调用 security（可能再次弹窗）")
    }

    static func securityHangs() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeLoggedInProfile("work")
        var env = home.environment
        env.security = try home.script("security-hangs", "exec /bin/sleep 30")
        env.securityTimeout = 0.5
        let start = Date()
        try expectEqual(home.loginStatus("work", env), .incompatible(.timedOut))
        try expect(Date().timeIntervalSince(start) < 5, "超时后应尽快返回")
    }

    static func noQueryWithoutAccount() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("fresh")
        try home.makeProfile("nokey", config: ["projects": [String: Any]()])
        try home.makeProfileDir("broken")
        try home.write(".claude-profiles/broken/.claude.json", "{not json")
        let profiles = home.profilesWithLogin()
        try expectEqual(profiles["default"]?.login?.status, .notLoggedIn)
        try expectEqual(profiles["fresh"]?.login?.status, .notLoggedIn)
        try expectEqual(profiles["nokey"]?.login?.status, .notLoggedIn)
        try expectEqual(profiles["broken"]?.login?.status, .accountUnreadable)
        try expectEqual(try home.securityCalls().count, 0, "没有账号资料时不应调用 security")
    }
}

func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
