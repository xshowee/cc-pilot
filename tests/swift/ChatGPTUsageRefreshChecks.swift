// chatgpt-profiles ticket 07：手动刷新 ChatGPT 额度（ChatGPTUsageRefresher → UsageBoard）。
// 请求 GET https://chatgpt.com/backend-api/wham/usage，头只有 Authorization、ChatGPT-Account-Id、User-Agent；
// 按 limit_window_seconds（18000 / 604800）识别窗口，不按位置；同一账号（用户 ID + 工作区 ID）只请求一次；
// 401 → 待续期；API key、未登录的档案不请求；令牌不出现在结果和输出里。网络层是假的（TempHome.transport）。
// 期望值来自 spec "手动刷新（API 契约）"，剩余百分比手算（100 − used_percent）。
//
// 响应夹具按 spec 列出的字段构造（email、plan_type、rate_limit.primary_window / secondary_window 的
// used_percent、limit_window_seconds、reset_at，另有 credits、model_usage），没有照抄真实响应；
// credits、model_usage 的内部结构 spec 没写，夹具里写 null，解析也不依赖它们。待真机核对（ticket 13）。

import Foundation

final class ChatGPTUsageRefreshChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("请求 wham/usage，头如实标明 cc-pilot，带令牌和工作区 ID", requestHeaders),
            Check("按 limit_window_seconds 识别窗口，不按位置；其他长度的窗口不显示", windowsByLength),
            Check("格式无法识别：两个窗口都显示—", unrecognizedFormat),
            Check("同一用户 + 同一工作区只请求一次，同一工作区的不同用户各请求一次", sameAccountRequestedOnce),
            Check("API key、未登录、读不懂的档案不请求；待续期的不发请求", onlyRequestableProfilesAreRequested),
            Check("401 → 待续期，不续期、不写 auth.json，也不再发别的请求", unauthorizedNeedsRenewal),
            Check("频率限制、其他状态码、网络失败同 Claude 一侧：保留上一次的数据", otherFailuresLikeClaude),
            Check("响应的 plan_type 更新套餐；邮箱对不上时不采用套餐，额度照常", reportedPlan),
            Check("与 Claude 的同名档案、同一看板互不相撞", doesNotCollideWithClaude),
            Check("令牌不出现在结果、失败原因、输出和 auth.json 以外的文件里", noTokenLeaks),
        ]
    }

    // MARK: - 夹具

    /// auth.json 里的 access token（假网络层按它返回响应）
    static func accessToken(_ auth: [String: Any]) -> String {
        (auth["tokens"] as! [String: Any])["access_token"] as! String
    }

    /// wham/usage 的一个窗口
    static func window(used: Double, seconds: Int, resetAt: TimeInterval? = nil) -> [String: Any] {
        var w: [String: Any] = ["used_percent": used, "limit_window_seconds": seconds]
        w["reset_at"] = resetAt.map { $0 as Any } ?? NSNull()
        return w
    }

    /// wham/usage 的响应体。primary / secondary 传 nil 时写 JSON null。
    static func whamJSON(email: String? = "me@example.com", plan: String? = "plus",
                         primary: [String: Any]? = window(used: 12, seconds: 18000,
                                                           resetAt: fixedNow.timeIntervalSince1970 + 3600),
                         secondary: [String: Any]? = window(used: 40, seconds: 604800,
                                                             resetAt: fixedNow.timeIntervalSince1970 + 300_000),
                         rateLimit: Any? = nil) -> String {
        var root: [String: Any] = ["credits": NSNull(), "model_usage": NSNull()]
        root["email"] = email.map { $0 as Any } ?? NSNull()
        root["plan_type"] = plan.map { $0 as Any } ?? NSNull()
        root["rate_limit"] = rateLimit ?? ["primary_window": primary.map { $0 as Any } ?? NSNull(),
                                           "secondary_window": secondary.map { $0 as Any } ?? NSNull()]
        let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func profiles(_ home: TempHome) -> [ChatGPTProfile] {
        ChatGPTProfileStore(environment: home.environment).listProfiles(now: fixedNow)
    }

    static func refresher(_ home: TempHome) -> ChatGPTUsageRefresher {
        ChatGPTUsageRefresher(environment: home.environment)
    }

    // MARK: - 检查

    static func requestHeaders() throws {
        let home = try TempHome()
        defer { home.remove() }
        let auth = chatgptAuth(workspaceID: "ws-team")
        try home.makeCodexDefault(auth: auth)
        home.transport.respond(toToken: accessToken(auth), body: whamJSON())

        let outcomes = refresher(home).refreshAll(profiles(home), now: fixedNow)

        try expectEqual(home.transport.requestCount, 1, "请求次数")
        let request = home.transport.requests[0]
        try expectEqual(request.httpMethod, "GET")
        try expectEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
        try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(accessToken(auth))")
        try expectEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "ws-team")
        try expectEqual(request.value(forHTTPHeaderField: "User-Agent"), "cc-pilot/\(TempHome.appVersion)")
        try expectEqual(Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }),
                        ["authorization", "chatgpt-account-id", "user-agent"], "只有这三个头")
        try expect(request.timeoutInterval <= 10, "超时应只有几秒：\(request.timeoutInterval)")
        try expectEqual(outcomes.count, 1, "结果个数")
        let snapshot = try unwrap(outcomes[0].outcome.result.snapshot, "应拿到额度：\(outcomes[0].outcome.result)")
        try expectEqual(snapshot.fiveHour?.remainingPercent, 88)
        try expectEqual(snapshot.sevenDay?.remainingPercent, 60)
    }

    /// 刷新唯一的默认档案，结果记进看板
    static func refreshDefault(_ home: TempHome, body: String) throws -> (UsageBoard, ChatGPTProfile) {
        let auth = chatgptAuth()
        try home.makeCodexDefault(auth: auth)
        home.transport.respond(toToken: accessToken(auth), body: body)
        let list = profiles(home)
        var board = UsageBoard()
        for outcome in refresher(home).refreshAll(list, now: fixedNow) { board.record(outcome.outcome) }
        return (board, list[0])
    }

    static func windowsByLength() throws {
        let base = fixedNow.timeIntervalSince1970
        // 位置互换：primary 是周窗口，secondary 是 5 小时窗口
        do {
            let home = try TempHome()
            defer { home.remove() }
            let (board, profile) = try refreshDefault(home, body: whamJSON(
                primary: window(used: 70, seconds: 604800, resetAt: base + 86400),
                secondary: window(used: 5.5, seconds: 18000, resetAt: base + 600)))
            let usage = try unwrap(board.usage(for: profile), "应有额度")
            try expectEqual(usage.fiveHour(now: fixedNow), .remaining(94, tint: .green), "5 小时窗口")
            try expectEqual(usage.fiveHourWindow?.window.resetsAt, Date(timeIntervalSince1970: base + 600))
            try expectEqual(usage.sevenDay(now: fixedNow), .remaining(30, tint: .yellow), "周窗口")
            try expectEqual(usage.sevenDayWindow?.window.resetsAt, Date(timeIntervalSince1970: base + 86400))
        }
        // 只有一个认识的窗口：另一个长度不认识，或是 null
        for secondary in [window(used: 50, seconds: 3600, resetAt: base + 600), nil] {
            let home = try TempHome()
            defer { home.remove() }
            let (board, profile) = try refreshDefault(home, body: whamJSON(
                primary: window(used: 90, seconds: 18000, resetAt: base + 600), secondary: secondary))
            let usage = try unwrap(board.usage(for: profile), "应有额度")
            try expectEqual(usage.fiveHour(now: fixedNow), .remaining(10, tint: .red), "5 小时窗口")
            try expectEqual(usage.sevenDay(now: fixedNow), nil, "周窗口不显示")
            try expectEqual(usage.problem, nil)
        }
        // rate_limit 为 null：没有窗口，不算格式无法识别
        do {
            let home = try TempHome()
            defer { home.remove() }
            let (board, profile) = try refreshDefault(home, body: whamJSON(rateLimit: NSNull()))
            let usage = try unwrap(board.usage(for: profile), "应有记录")
            try expectEqual(usage.fiveHour(now: fixedNow), nil)
            try expectEqual(usage.sevenDay(now: fixedNow), nil)
            try expectEqual(usage.problem, nil)
        }
        // 已重置、变灰沿用 Claude 一侧的规则
        do {
            let home = try TempHome()
            defer { home.remove() }
            let (board, profile) = try refreshDefault(home, body: whamJSON())
            let usage = try unwrap(board.usage(for: profile), "应有额度")
            try expectEqual(usage.fiveHour(now: fixedNow.addingTimeInterval(31 * 60)), .remaining(88, tint: .stale))
            try expectEqual(usage.fiveHour(now: fixedNow.addingTimeInterval(3600)), .resetPendingRefresh)
        }
    }

    static func unrecognizedFormat() throws {
        for body in ["not json", "[]", #"{"email":"me@example.com","plan_type":"plus"}"#,
                     whamJSON(rateLimit: "limited")] {
            let home = try TempHome()
            defer { home.remove() }
            let (board, profile) = try refreshDefault(home, body: body)
            let usage = try unwrap(board.usage(for: profile), "应有记录：\(body)")
            try expectEqual(usage.problem, .unrecognizedFormat, body)
            try expectEqual(usage.fiveHour(now: fixedNow), .unavailable, body)
            try expectEqual(usage.sevenDay(now: fixedNow), .unavailable, body)
        }
    }

    static func sameAccountRequestedOnce() throws {
        let home = try TempHome()
        defer { home.remove() }
        let me = chatgptAuth(userID: "user-me", workspaceID: "ws-team")
        let colleague = chatgptAuth(email: "colleague@example.com", userID: "user-colleague", workspaceID: "ws-team")
        try home.makeCodexDefault(auth: me)
        try home.makeCodexProfile("again", auth: me)
        try home.makeCodexProfile("colleague", auth: colleague)
        home.transport.respond(toToken: accessToken(me), body: whamJSON(
            primary: window(used: 10, seconds: 18000), secondary: nil))
        home.transport.respond(toToken: accessToken(colleague), body: whamJSON(
            email: "colleague@example.com", primary: window(used: 70, seconds: 18000), secondary: nil))
        let list = profiles(home)

        var board = UsageBoard()
        let outcomes = refresher(home).refreshAll(list, now: fixedNow)
        for outcome in outcomes { board.record(outcome.outcome) }

        try expectEqual(home.transport.requestCount, 2, "请求次数")
        try expectEqual(outcomes.count, 2, "结果个数")
        try expectEqual(Set(home.transport.requests.map { $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") }),
                        ["ws-team"], "工作区 ID")
        let named = Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
        try expectEqual(board.usage(for: named["default"]!)?.fiveHour(now: fixedNow), .remaining(90, tint: .green))
        try expectEqual(board.usage(for: named["again"]!)?.fiveHour(now: fixedNow), .remaining(90, tint: .green))
        try expectEqual(board.usage(for: named["colleague"]!)?.fiveHour(now: fixedNow), .remaining(30, tint: .yellow))

        // 刷新单个账号只请求这个账号
        let before = home.transport.requestCount
        let one = refresher(home).refresh(named["colleague"]!.usageAccount!, in: list, now: fixedNow)
        try expectEqual(home.transport.requests.dropFirst(before).map { $0.value(forHTTPHeaderField: "Authorization") },
                        ["Bearer \(accessToken(colleague))"])
        try expectEqual(one.account, named["colleague"]!.usageAccount!)

        // 同一账号的第一个档案待续期时，改用这个账号里可以请求的档案，仍只请求一次
        let other = try TempHome()
        defer { other.remove() }
        let fresh = chatgptAuth(userID: "user-me", workspaceID: "ws-team")
        try other.makeCodexDefault(auth: chatgptAuth(userID: "user-me", workspaceID: "ws-team", accessExp: 3600))
        try other.makeCodexProfile("again", auth: fresh)
        let otherList = profiles(other)
        try other.writeJSON(".codex/auth.json", chatgptAuth(userID: "user-me", workspaceID: "ws-team", accessExp: -60))
        other.transport.respond(toToken: accessToken(fresh), body: whamJSON())
        let retried = refresher(other).refreshAll(otherList, now: fixedNow)
        try expectEqual(other.transport.requestCount, 1, "请求次数")
        try expectEqual(retried.map { $0.outcome.result.snapshot?.fiveHour?.remainingPercent }, [88])
    }

    static func onlyRequestableProfilesAreRequested() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault(auth: apiKeyAuth())
        try home.makeCodexProfile("empty")
        try home.makeCodexProfile("garbled")
        try home.write(".codex-profiles/garbled/auth.json", "oops \(ChatGPTSentinel.accessSignature)")
        let expired = chatgptAuth(email: "renew@example.com", userID: "user-renew", accessExp: -60)
        try home.makeCodexProfile("renew", auth: expired)
        home.transport.respond(toToken: accessToken(expired), body: whamJSON())
        let list = profiles(home)

        let outcomes = refresher(home).refreshAll(list, now: fixedNow)
        try expectEqual(home.transport.requestCount, 0, "请求次数")
        let accounts = list.compactMap(\.usageAccount)
        try expectEqual(accounts, [list.first { $0.name == "renew" }!.usageAccount!], "只有待续期的档案有账号")
        try expectEqual(outcomes.map(\.outcome.result), [.denied(.needsRenewal)])

        var board = UsageBoard()
        for outcome in outcomes { board.record(outcome.outcome) }
        try expectEqual(board.usage(for: list.first { $0.name == "renew" }!)?.problem, .login(.needsRenewal))
        for name in ["default", "empty", "garbled"] {
            try expect(board.usage(for: list.first { $0.name == name }!) == nil, "\(name) 不应有额度记录")
        }
    }

    static func unauthorizedNeedsRenewal() throws {
        let home = try TempHome()
        defer { home.remove() }
        let auth = chatgptAuth()
        try home.makeCodexDefault(auth: auth)
        let authFile = home.url.appendingPathComponent(".codex/auth.json")
        let before = try Data(contentsOf: authFile)
        let modified = try FileManager.default.attributesOfItem(atPath: authFile.path)[.modificationDate] as? Date
        home.transport.respond(toToken: accessToken(auth), body: whamJSON())
        let list = profiles(home)
        var board = UsageBoard()
        board.record(refresher(home).refreshAll(list, now: fixedNow)[0].outcome)

        home.transport.respond(toToken: accessToken(auth), FakeUsageTransport.Response(
            status: 401, body: #"{"detail":"Unauthorized"}"#))
        let outcome = refresher(home).refresh(list[0].usageAccount!, in: list, now: fixedNow.addingTimeInterval(60))
        try expectEqual(outcome.outcome.result, .unauthorized(.needsRenewal))
        try expectEqual(outcome.reported, nil)
        try expectEqual(home.transport.requestCount, 2, "只发了额度请求，没有尝试续期")
        try expect(home.transport.requests.allSatisfy {
            $0.httpMethod == "GET" && $0.url == ChatGPTUsageRefresher.usageEndpoint
        }, "只请求 wham/usage")
        try expectEqual(try Data(contentsOf: authFile), before, "auth.json 没被改写")
        try expectEqual(try FileManager.default.attributesOfItem(atPath: authFile.path)[.modificationDate] as? Date,
                        modified, "auth.json 的修改时间")

        board.record(outcome.outcome)
        let usage = try unwrap(board.usage(for: list[0]), "应有记录")
        try expectEqual(usage.problem, .login(.needsRenewal))
        try expectEqual(usage.fiveHour(now: fixedNow.addingTimeInterval(60)), .remaining(88, tint: .green),
                        "保留上一次的数据")
    }

    static func otherFailuresLikeClaude() throws {
        let home = try TempHome()
        defer { home.remove() }
        let auth = chatgptAuth()
        try home.makeCodexDefault(auth: auth)
        let token = accessToken(auth)
        home.transport.respond(toToken: token, body: whamJSON())
        let list = profiles(home)
        let account = list[0].usageAccount!
        var board = UsageBoard()
        board.record(refresher(home).refresh(account, in: list, now: fixedNow).outcome)

        home.transport.respond(toToken: token, FakeUsageTransport.Response(
            status: 429, headers: ["retry-after": "120"], body: "{}"))
        let limited = refresher(home).refresh(account, in: list, now: fixedNow)
        try expectEqual(limited.outcome.result, .rateLimited(until: fixedNow.addingTimeInterval(120)))
        board.record(limited.outcome)
        try expectEqual(board.accountsAllowedToRefresh([account], now: fixedNow.addingTimeInterval(60)), [],
                        "等待期内不请求")
        try expectEqual(board.usage(for: list[0])?.problem, .rateLimited)

        home.transport.respond(toToken: token, FakeUsageTransport.Response(status: 500, body: "{}"))
        let status = refresher(home).refresh(account, in: list, now: fixedNow)
        try expectEqual(status.outcome.result, .httpStatus(500))
        board.record(status.outcome)
        try expectEqual(board.usage(for: list[0])?.problem, .httpStatus(500))

        home.transport.forget(token: token)
        let offline = refresher(home).refresh(account, in: list, now: fixedNow)
        try expectEqual(offline.outcome.result, .networkFailure)
        board.record(offline.outcome)
        let usage = try unwrap(board.usage(for: list[0]), "应有记录")
        try expectEqual(usage.problem, .networkFailure)
        try expectEqual(usage.fiveHour(now: fixedNow), .remaining(88, tint: .green), "保留上一次的数据")
        try expectEqual(usage.updatedAt, fixedNow, "获取时间是上一次成功的时间")
    }

    static func reportedPlan() throws {
        let home = try TempHome()
        defer { home.remove() }
        let match = chatgptAuth(email: "Me@Example.com", plan: "plus", userID: "user-me")
        let mismatch = chatgptAuth(email: "other@example.com", plan: "plus", userID: "user-other")
        try home.makeCodexDefault(auth: match)
        try home.makeCodexProfile("mismatch", auth: mismatch)
        home.transport.respond(toToken: accessToken(match), body: whamJSON(email: "me@example.com", plan: "pro"))
        home.transport.respond(toToken: accessToken(mismatch), body: whamJSON(email: "someone@example.com", plan: "team"))
        let outcomes = refresher(home).refreshAll(profiles(home), now: fixedNow)
        try expectEqual(outcomes.map(\.reported), [ChatGPTReportedAccount(planType: "pro"),
                                                   ChatGPTReportedAccount(planType: nil)])
        try expectEqual(outcomes.map { $0.outcome.result.snapshot?.fiveHour?.remainingPercent }, [88, 88],
                        "额度照常采用")
    }

    static func doesNotCollideWithClaude() throws {
        let home = try TempHome()
        defer { home.remove() }
        // Claude 与 ChatGPT 各有一个叫 work 的档案
        try home.keychainItem(service: home.makeLoggedInProfile("work", uuid: "u-work"),
                              credentialJSON(access: "token-claude"))
        home.transport.respond(toToken: "token-claude", body: usageJSON(fiveHour: .used(80, resetsAt: nil)))
        let auth = chatgptAuth()
        try home.makeCodexDefault()
        try home.makeCodexProfile("work", auth: auth)
        home.transport.respond(toToken: accessToken(auth), body: whamJSON())

        let claude = ProfileStore(environment: home.environment).listProfiles()
        let chatgpt = profiles(home)
        var board = UsageBoard()
        for outcome in UsageRefresher(environment: home.environment).refreshAll(claude, now: fixedNow) {
            board.record(outcome)
        }
        for outcome in refresher(home).refreshAll(chatgpt, now: fixedNow) { board.record(outcome.outcome) }
        let claudeWork = claude.first { $0.name == "work" }!
        let chatgptWork = chatgpt.first { $0.name == "work" }!
        try expect(claudeWork.usageAccount != chatgptWork.usageAccount, "账号键不同")
        try expectEqual(board.usage(for: claudeWork)?.fiveHour(now: fixedNow), .remaining(20, tint: .red))
        try expectEqual(board.usage(for: chatgptWork)?.fiveHour(now: fixedNow), .remaining(88, tint: .green))
    }

    static func noTokenLeaks() throws {
        let home = try TempHome()
        defer { home.remove() }
        let ok = chatgptAuth(userID: "user-ok")
        let denied = chatgptAuth(userID: "user-401")
        let broken = chatgptAuth(userID: "user-500")
        try home.makeCodexDefault(auth: ok)
        try home.makeCodexProfile("denied", auth: denied)
        try home.makeCodexProfile("broken", auth: broken)
        try home.makeCodexProfile("offline", auth: chatgptAuth(userID: "user-offline"))
        try home.makeCodexProfile("renew", auth: chatgptAuth(userID: "user-renew", accessExp: -60))
        home.transport.respond(toToken: accessToken(ok), body: whamJSON())
        home.transport.respond(toToken: accessToken(denied), FakeUsageTransport.Response(status: 401, body: "{}"))
        home.transport.respond(toToken: accessToken(broken), FakeUsageTransport.Response(status: 500, body: "{}"))

        var texts: [String] = []
        let log = home.root.appendingPathComponent("captured-output.log")
        try CredentialSafetyChecks.capturingOutput(to: log) {
            let outcomes = refresher(home).refreshAll(profiles(home), now: fixedNow)
            var board = UsageBoard()
            for outcome in outcomes { board.record(outcome.outcome) }
            texts += CredentialSafetyChecks.renderings(outcomes) + CredentialSafetyChecks.renderings(board)
        }
        try expectEqual(home.transport.requestCount, 4, "请求次数（确认确实用到了令牌）")
        func expectClean(_ data: Data, _ what: String) throws {
            for sentinel in ChatGPTSentinel.all {
                try expect(data.range(of: Data(sentinel.utf8)) == nil, "\(what) 里出现了令牌")
            }
        }
        for text in texts { try expectClean(Data(text.utf8), "结果的文字形式：\(text.prefix(200))") }
        try expectClean(try Data(contentsOf: log), "App 核心的输出（日志）")
        var scanned = 0
        for file in try CredentialSafetyChecks.allFiles(under: home.root) where !file.hasSuffix("/auth.json") {
            try expectClean(try Data(contentsOf: URL(fileURLWithPath: file)), "文件 \(file)")
            scanned += 1
        }
        try expect(scanned > 0, "没有扫描任何文件")
    }
}
