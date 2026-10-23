// ticket 11：刷新额度。只有"可以请求额度"的账号才发请求，请求头如实标明 cc-pilot；
// 同一账号一次刷新只请求一次；剩余百分比 = 100 − utilization。网络层是假的（TempHome.transport）。
// 期望值来自 spec "额度接口"一节。

import Foundation

final class UsageRefreshChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("只有可以请求额度的账号才发请求，请求头如实标明 cc-pilot", onlyRequestableAccountsAreRequested),
            Check("多个档案登录同一账号：刷新全部只请求一次，结果显示在所有这些档案上", sameAccountRequestedOnce),
            Check("刷新单个账号只请求这个账号", refreshOneAccount),
            Check("菜单栏第二行是当前档案所在账号的 5 小时窗口剩余；没刷新过时是—", menuBarFollowsCurrentProfile),
            Check("启动、打开面板（重载档案列表）、切换档案都不发请求", noRequestsWithoutRefresh),
            Check("网络失败、频率限制、401、其他状态码时保留上一次成功获取的数据", failureKeepsLastSnapshot),
            Check("刷新的结果、日志和磁盘文件里都没有凭据", refreshDoesNotLeakCredentials),
            Check("检查程序注入的网络层是假的，不访问真的网络", checksNeverUseRealNetwork),
        ]
    }

    static func onlyRequestableAccountsAreRequested() throws {
        let home = try TempHome()
        defer { home.remove() }
        let cases: [(String, String?)] = [
            ("ok", credentialJSON()),
            ("renew", credentialJSON(access: "token-renew", expiresAt: ms(-60))),
            ("relogin", credentialJSON(access: "token-relogin", refresh: "")),
            ("unsupported", credentialJSON(access: "token-unsupported", scopes: ["user:inference"])),
            ("missing", nil),
        ]
        for (i, (name, json)) in cases.enumerated() {
            let svc = try home.makeLoggedInProfile(name, uuid: "u\(i)")
            if let json { try home.keychainItem(service: svc, json) }
        }
        try home.makeProfileDir("fresh")
        for token in [Sentinel.accessToken, "token-renew", "token-relogin", "token-unsupported"] {
            home.transport.respond(toToken: token, body: usageJSON())
        }

        let profiles = ProfileStore(environment: home.environment).listProfiles()
        let outcomes = UsageRefresher(environment: home.environment).refreshAll(profiles, now: fixedNow)

        try expectEqual(home.transport.requestCount, 1, "请求次数")
        let request = home.transport.requests[0]
        try expectEqual(request.httpMethod, "GET")
        try expectEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(Sentinel.accessToken)")
        try expectEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        try expectEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        try expectEqual(request.value(forHTTPHeaderField: "User-Agent"), "cc-pilot/\(TempHome.appVersion)")
        try expect(request.timeoutInterval <= 10, "超时应只有几秒：\(request.timeoutInterval)")

        // 每个已登录的账号都有一个结果；未登录的档案没有账号，不参与
        let byProfile = Dictionary(uniqueKeysWithValues: profiles.compactMap { p in
            p.usageAccount.map { (p.name, $0) }
        })
        try expectEqual(Set(byProfile.keys), ["ok", "renew", "relogin", "unsupported", "missing"])
        let results = Dictionary(uniqueKeysWithValues: outcomes.map { ($0.account, $0.result) })
        try expectEqual(results.count, 5, "结果个数")
        func result(_ name: String) -> UsageFetchResult? { byProfile[name].flatMap { results[$0] } }
        try expect(result("ok")?.snapshot != nil, "ok 应拿到额度：\(String(describing: result("ok")))")
        try expectEqual(result("renew"), .denied(.needsRenewal))
        try expectEqual(result("relogin"), .denied(.needsReLogin))
        try expectEqual(result("unsupported"), .denied(.usageUnsupported))
        try expectEqual(result("missing"), .denied(.incompatible(.itemNotFound)))
    }

    /// default、work 登录同一账号（令牌不同），solo 是另一个账号
    static func prepareSharedAccount(_ home: TempHome, defaultCredential: String = credentialJSON(access: "token-default")) throws {
        try home.keychainItem(service: home.makeLoggedInProfile("default", uuid: "u-shared"), defaultCredential)
        try home.keychainItem(service: home.makeLoggedInProfile("work", uuid: "u-shared"),
                              credentialJSON(access: "token-work"))
        try home.keychainItem(service: home.makeLoggedInProfile("solo", uuid: "u-solo"),
                              credentialJSON(access: "token-solo"))
        home.transport.respond(toToken: "token-default", body: usageJSON(fiveHour: .used(10, resetsAt: nil)))
        home.transport.respond(toToken: "token-work", body: usageJSON(fiveHour: .used(20, resetsAt: nil)))
        home.transport.respond(toToken: "token-solo", body: usageJSON(fiveHour: .used(70, resetsAt: nil)))
    }

    static func sameAccountRequestedOnce() throws {
        let home = try TempHome()
        defer { home.remove() }
        try prepareSharedAccount(home)
        let profiles = ProfileStore(environment: home.environment).listProfiles()

        var board = UsageBoard()
        for outcome in UsageRefresher(environment: home.environment).refreshAll(profiles, now: fixedNow) {
            board.record(outcome)
        }
        try expectEqual(home.transport.requestCount, 2, "请求次数")
        let named = Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0) })
        // 用的是同一账号里第一个档案（default）的凭据
        try expectEqual(board.snapshot(for: named["default"]!)?.fiveHour?.remainingPercent, 90)
        try expectEqual(board.snapshot(for: named["work"]!)?.fiveHour?.remainingPercent, 90)
        try expectEqual(board.snapshot(for: named["solo"]!)?.fiveHour?.remainingPercent, 30)

        // 同一账号的第一个档案待续期时，改用这个账号里可以请求的档案，仍只请求一次
        let other = try TempHome()
        defer { other.remove() }
        try prepareSharedAccount(other, defaultCredential: credentialJSON(access: "token-default", expiresAt: ms(-60)))
        let outcomes = UsageRefresher(environment: other.environment)
            .refreshAll(ProfileStore(environment: other.environment).listProfiles(), now: fixedNow)
        try expectEqual(other.transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                        ["Bearer token-work", "Bearer token-solo"])
        try expectEqual(outcomes.compactMap { $0.result.snapshot?.fiveHour?.remainingPercent }, [80, 30])
    }

    static func refreshOneAccount() throws {
        let home = try TempHome()
        defer { home.remove() }
        try prepareSharedAccount(home)
        let profiles = ProfileStore(environment: home.environment).listProfiles()
        let solo = profiles.first { $0.name == "solo" }!

        var board = UsageBoard()
        board.record(UsageRefresher(environment: home.environment)
            .refresh(solo.usageAccount!, in: profiles, now: fixedNow))
        try expectEqual(home.transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                        ["Bearer token-solo"])
        try expectEqual(board.snapshot(for: solo)?.fiveHour?.remainingPercent, 30)
        try expect(board.snapshot(for: profiles[0]) == nil, "没刷新的账号不应有数据")
    }

    static func menuBarFollowsCurrentProfile() throws {
        let home = try TempHome()
        defer { home.remove() }
        try prepareSharedAccount(home)
        try home.makeProfileDir("fresh")
        let profiles = ProfileStore(environment: home.environment).listProfiles()

        var board = UsageBoard()
        try expectEqual(board.menuBarSummary(currentProfile: "work", profiles: profiles, now: fixedNow).quotaLine(resetText: "Reset"), "—",
                        "没刷新过")
        for outcome in UsageRefresher(environment: home.environment).refreshAll(profiles, now: fixedNow) {
            board.record(outcome)
        }
        try expectEqual(board.menuBarSummary(currentProfile: "work", profiles: profiles, now: fixedNow),
                        MenuBarSummary(profileName: "work", fiveHour: .remaining(90, tint: .plain)))
        try expectEqual(board.menuBarSummary(currentProfile: "solo", profiles: profiles, now: fixedNow).quotaLine(resetText: "Reset"), "30%")
        try expectEqual(board.menuBarSummary(currentProfile: "fresh", profiles: profiles, now: fixedNow),
                        MenuBarSummary(profileName: "fresh"), "未登录的档案")
        try expectEqual(board.menuBarSummary(currentProfile: "gone", profiles: profiles, now: fixedNow),
                        MenuBarSummary(profileName: "gone"), "当前档案记录指向已不存在的档案")

        // 5 小时窗口的 utilization 为 null：没有数字可显示
        home.transport.respond(toToken: "token-solo", body: usageJSON(fiveHour: .used(nil, resetsAt: nil)))
        board.record(UsageRefresher(environment: home.environment)
            .refresh(profiles.first { $0.name == "solo" }!.usageAccount!, in: profiles, now: fixedNow))
        try expectEqual(board.menuBarSummary(currentProfile: "solo", profiles: profiles, now: fixedNow).quotaLine(resetText: "Reset"), "—")
    }

    static func noRequestsWithoutRefresh() throws {
        let home = try TempHome()
        defer { home.remove() }
        try prepareSharedAccount(home)
        let env = home.environment
        let board = UsageBoard()
        let record = CurrentProfileRecord(environment: env)

        // 启动：读档案列表、判定登录状态、读当前档案、算菜单栏
        var profiles = LoginChecker(environment: env).withLoginStates(ProfileStore(environment: env).listProfiles())
        _ = board.menuBarSummary(currentProfile: record.currentName(), profiles: profiles, now: fixedNow)
        // 打开面板：重载档案列表，按档案查额度
        profiles = LoginChecker(environment: env).withLoginStates(ProfileStore(environment: env).listProfiles())
        for p in profiles { _ = board.snapshot(for: p) }
        // 切换档案
        try record.switchTo("solo")
        _ = board.menuBarSummary(currentProfile: record.currentName(), profiles: profiles, now: fixedNow)
        try expectEqual(home.transport.requestCount, 0, "没有点刷新时的请求次数")

        // 对照：点了刷新才有请求，说明计数有效
        _ = UsageRefresher(environment: env).refreshAll(profiles, now: fixedNow)
        try expectEqual(home.transport.requestCount, 2)
    }

    static func failureKeepsLastSnapshot() throws {
        let home = try TempHome()
        defer { home.remove() }
        try prepareSharedAccount(home)
        let profiles = ProfileStore(environment: home.environment).listProfiles()
        let solo = profiles.first { $0.name == "solo" }!
        let refresher = UsageRefresher(environment: home.environment)

        var board = UsageBoard()
        board.record(refresher.refresh(solo.usageAccount!, in: profiles, now: fixedNow))
        let first = board.snapshot(for: solo)
        try expectEqual(first?.fetchedAt, fixedNow)

        let later = fixedNow.addingTimeInterval(600)
        let failures: [(FakeUsageTransport.Response?, UsageFetchResult)] = [
            (FakeUsageTransport.Response(status: 429, headers: ["Retry-After": "120"], body: "{}"),
             .rateLimited(until: later.addingTimeInterval(120))),
            (FakeUsageTransport.Response(status: 500, body: usageJSON()), .httpStatus(500)),
            (FakeUsageTransport.Response(status: 401, body: "{}"), .unauthorized(.needsRenewal)),
            (nil, .networkFailure),
            // 格式无法识别时不保留旧数字（显示"—"），见 UsageFailureChecks
        ]
        for (response, expected) in failures {
            if let response {
                home.transport.respond(toToken: "token-solo", response)
            } else {
                home.transport.forget(token: "token-solo")
            }
            let outcome = refresher.refresh(solo.usageAccount!, in: profiles, now: later)
            try expectEqual(outcome.result, expected)
            board.record(outcome)
            try expectEqual(board.snapshot(for: solo), first, "\(expected) 后应保留上次的数据")
        }
    }

    static func refreshDoesNotLeakCredentials() throws {
        let home = try TempHome()
        defer { home.remove() }
        // 成功、401、网络失败、格式无法识别各一个账号，都用哨兵令牌
        let responses: [(String, FakeUsageTransport.Response?)] = [
            ("ok", FakeUsageTransport.Response(body: usageJSON())),
            ("unauthorized", FakeUsageTransport.Response(status: 401, body: #"{"error":"x"}"#)),
            ("offline", nil),
            ("garbled", FakeUsageTransport.Response(body: "<html>")),
        ]
        let log = home.root.appendingPathComponent("captured-output.log")
        var texts: [String] = []
        for (i, (name, response)) in responses.enumerated() {
            try home.keychainItem(service: home.makeLoggedInProfile(name, uuid: "u\(i)"), credentialJSON())
            try CredentialSafetyChecks.capturingOutput(to: log) {
                if let response { home.transport.respond(toToken: Sentinel.accessToken, response) }
                else { home.transport.forget(token: Sentinel.accessToken) }
                let profiles = ProfileStore(environment: home.environment).listProfiles()
                let profile = profiles.first { $0.name == name }!
                let outcome = UsageRefresher(environment: home.environment)
                    .refresh(profile.usageAccount!, in: profiles, now: fixedNow)
                var board = UsageBoard()
                board.record(outcome)
                texts += CredentialSafetyChecks.renderings(outcome) + CredentialSafetyChecks.renderings(board)
            }
            try CredentialSafetyChecks.expectNoSentinel(try Data(contentsOf: log), "\(name) 刷新时的输出")
        }
        try expectEqual(home.transport.requestCount, 4, "确实发出了带令牌的请求")
        for t in texts { try CredentialSafetyChecks.expectNoSentinel(Data(t.utf8), "结果的文字形式：\(t.prefix(200))") }
        let items = home.fakeSecurityDir.appendingPathComponent("items").path
        for file in try CredentialSafetyChecks.allFiles(under: home.root) where !file.hasPrefix(items + "/") {
            try CredentialSafetyChecks.expectNoSentinel(try Data(contentsOf: URL(fileURLWithPath: file)), "文件 \(file)")
        }
    }

    static func checksNeverUseRealNetwork() throws {
        let home = try TempHome()
        defer { home.remove() }
        try expect(home.environment.transport as AnyObject === home.transport, "TempHome 应注入自己的假网络层")
        try expect(!(home.environment.transport is URLSessionUsageTransport), "不应是真的网络层")
    }
}
