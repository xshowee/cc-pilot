// 手动刷新 Kimi Code 额度（KimiUsageRefresher → UsageBoard，ADR 0007）。
// 请求 GET https://api.kimi.com/coding/v1/usages，头只有 Authorization、User-Agent；只读 usages.limit_5h / limit_7d，
// 顶层的 usage、limits[] 不读；没有 key 不请求；401 → key 被拒绝；key 不出现在结果里。
// 网络层和 key 存放处都是假的（TempHome.transport、TempHome.kimiKeys）。
//
// realBody 是 2026-11-10 真实响应的原文（不含任何凭据），只把时间换成相对 fixedNow 的；
// 期望的剩余百分比手算：100 − used_ratio × 100，向下取整（0.1101 → 已用 11.01% → 剩余 88%）。

import Foundation

final class KimiUsageRefreshChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("请求 /coding/v1/usages，头如实标明 cc-pilot，只带 key", requestHeaders),
            Check("真实响应：5 小时窗口和周窗口取自 usages，剩余按 used_ratio 手算", realResponse),
            Check("没有 usages 就是格式无法识别，不拿顶层的 usage、limits 猜", noGuessingFromUnlabeledFields),
            Check("used_ratio 不是数字的窗口不显示", windowWithoutNumber),
            Check("没有 key 不请求，也不读 key；读不到 key 不请求", noRequestWithoutKey),
            Check("401 → key 被拒绝；429 → 频率限制；403 等原样记录；都保留上一次的数据", failures),
            Check("成功的刷新替换旧数字：同一窗口里已用比例下降也照新的显示", successReplaces),
            Check("删除账号后忘掉它的数字：同名再加另一个 key 失败时不显示旧的", forgetOnKeyChange),
            Check("多个账号各用各的 key、各记各的额度；账号名称的规则", multipleAccounts),
            Check("key 不出现在结果和失败原因里", noKeyLeaks),
        ]
    }

    // MARK: - 夹具

    /// 假的 key（不是真实的 key；假网络层按它返回响应）
    static let key = "sk-kimi-FAKE-check-key-0000"
    /// 账号名称
    static let name = "work"

    static let fiveHourReset = "2027-01-15T10:00:00Z"   // fixedNow + 2 小时
    static let sevenDayReset = "2027-01-16T03:00:00Z"   // fixedNow + 19 小时

    /// 真实响应的原文（2026-11-10），时间换成上面两个
    static let realBody = """
        {"usage":{"limit":"100","used":"11","remaining":"89","resetTime":"2027-01-16T03:00:00.808540Z"},\
        "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},\
        "detail":{"limit":"100","remaining":"100","resetTime":"2027-01-15T10:00:00.808540Z"}}],\
        "usages":{"limit_5h":{"used_ratio":0,"reset_time":"\(fiveHourReset)"},\
        "limit_7d":{"used_ratio":0.1101,"reset_time":"\(sevenDayReset)"}}}
        """

    static func body(fiveHour: Any?, sevenDay: Any?) -> String {
        var usages: [String: Any] = [:]
        if let fiveHour { usages["limit_5h"] = fiveHour }
        if let sevenDay { usages["limit_7d"] = sevenDay }
        let data = try! JSONSerialization.data(withJSONObject: ["usages": usages], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func window(_ ratio: Any, reset: String) -> [String: Any] {
        ["used_ratio": ratio, "reset_time": reset]
    }

    static let iso: ISO8601DateFormatter = ISO8601DateFormatter()

    /// 保存 key、准备响应、刷新一次并记进看板
    static func refreshed(_ home: TempHome, body: String, into board: inout UsageBoard) throws {
        try home.kimiKeys.save(key, for: name)
        home.transport.respond(toToken: key, body: body)
        board.recordReplacing(KimiUsageRefresher(environment: home.environment).refresh(name, now: fixedNow))
    }

    static func usage(_ board: UsageBoard) -> AccountUsage? {
        board.usage(for: KimiUsageRefresher.account(name))
    }

    // MARK: - 检查

    static func requestHeaders() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.kimiKeys.save(key, for: name)
        home.transport.respond(toToken: key, body: realBody)

        let outcome = KimiUsageRefresher(environment: home.environment).refresh(name, now: fixedNow)

        try expectEqual(home.transport.requestCount, 1, "请求次数")
        let request = home.transport.requests[0]
        try expectEqual(request.httpMethod, "GET")
        try expectEqual(request.url?.absoluteString, "https://api.kimi.com/coding/v1/usages")
        try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        try expectEqual(request.value(forHTTPHeaderField: "User-Agent"), "cc-pilot/\(TempHome.appVersion)")
        try expectEqual(Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }),
                        ["authorization", "user-agent"], "只有这两个头")
        try expect(request.timeoutInterval <= 10, "超时应只有几秒：\(request.timeoutInterval)")
        try expectEqual(outcome.account, KimiUsageRefresher.account(name))
        try expect(outcome.result.snapshot != nil, "应拿到额度：\(outcome.result)")
    }

    static func realResponse() throws {
        let home = try TempHome()
        defer { home.remove() }
        var board = UsageBoard()
        try refreshed(home, body: realBody, into: &board)

        let usage = try unwrap(usage(board), "应有额度")
        try expectEqual(usage.problem, nil)
        try expectEqual(usage.fiveHour(now: fixedNow), .remaining(100, tint: .green), "5 小时窗口")
        try expectEqual(usage.fiveHourWindow?.window.resetsAt, iso.date(from: fiveHourReset))
        try expectEqual(usage.sevenDay(now: fixedNow), .remaining(88, tint: .green), "周窗口")
        try expectEqual(usage.sevenDayWindow?.window.resetsAt, iso.date(from: sevenDayReset))
        try expectEqual(usage.modelWeekly(now: fixedNow), [], "没有按模型细分的周窗口")
        try expectEqual(usage.extraUsage(now: fixedNow), nil, "没有超额付费")
        // 已重置、变灰沿用 Claude 一侧的规则
        try expectEqual(usage.sevenDay(now: fixedNow.addingTimeInterval(31 * 60)), .remaining(88, tint: .stale))
        try expectEqual(usage.fiveHour(now: fixedNow.addingTimeInterval(2 * 3600)), .resetPendingRefresh)
    }

    static func noGuessingFromUnlabeledFields() throws {
        // 第三方文档记载的旧格式：只有顶层 usage 和 limits[]
        let old = """
            {"usage":{"limit":"2048","used":"214","remaining":"1834","resetTime":"\(sevenDayReset)"},\
            "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},\
            "detail":{"limit":"200","used":"139","remaining":"61","resetTime":"\(fiveHourReset)"}}]}
            """
        for bad in [old, "{}", "[]", "not json", #"{"usages":null}"#, #"{"usages":{}}"#, #"{"usages":{"other":1}}"#] {
            let home = try TempHome()
            defer { home.remove() }
            var board = UsageBoard()
            try refreshed(home, body: realBody, into: &board)
            try refreshed(home, body: bad, into: &board)
            let usage = try unwrap(usage(board), "应有记录")
            try expectEqual(usage.problem, .unrecognizedFormat, bad)
            try expectEqual(usage.fiveHour(now: fixedNow), .unavailable, "旧数字不再显示：\(bad)")
            try expectEqual(usage.sevenDay(now: fixedNow), .unavailable, "旧数字不再显示：\(bad)")
        }
    }

    static func windowWithoutNumber() throws {
        let cases: [(Any?, Any?)] = [
            (window(0.5, reset: fiveHourReset), nil),
            (window(0.5, reset: fiveHourReset), NSNull()),
            (window(0.5, reset: fiveHourReset), window(NSNull(), reset: sevenDayReset)),
            (window(0.5, reset: fiveHourReset), window("0.4", reset: sevenDayReset)),
            (window(0.5, reset: fiveHourReset), ["reset_time": sevenDayReset]),
        ]
        for (five, seven) in cases {
            let home = try TempHome()
            defer { home.remove() }
            var board = UsageBoard()
            try refreshed(home, body: body(fiveHour: five, sevenDay: seven), into: &board)
            let usage = try unwrap(usage(board), "应有额度")
            try expectEqual(usage.problem, nil)
            try expectEqual(usage.fiveHour(now: fixedNow), .remaining(50, tint: .yellow), "5 小时窗口")
            try expectEqual(usage.sevenDay(now: fixedNow), nil, "周窗口不显示")
        }
        // 超出 0–1 的比例不会显示成负数或超过 100
        let home = try TempHome()
        defer { home.remove() }
        var board = UsageBoard()
        try refreshed(home, body: body(fiveHour: window(1.2, reset: fiveHourReset),
                                       sevenDay: window(-0.1, reset: sevenDayReset)), into: &board)
        try expectEqual(usage(board)?.fiveHour(now: fixedNow), .remaining(0, tint: .red))
        try expectEqual(usage(board)?.sevenDay(now: fixedNow), .remaining(100, tint: .green))
    }

    static func noRequestWithoutKey() throws {
        let home = try TempHome()
        defer { home.remove() }
        let refresher = KimiUsageRefresher(environment: home.environment)

        try expectEqual(refresher.refresh(name, now: fixedNow).result, .denied(.notLoggedIn), "没有 key")
        try expectEqual(home.kimiKeys.readCount, 0, "没有 key 时不读")

        try home.kimiKeys.save(key, for: name)
        home.kimiKeys.makeUnreadable()
        home.transport.respond(toToken: key, body: realBody)
        try expectEqual(refresher.refresh(name, now: fixedNow).result, .denied(.accountUnreadable), "读不到 key")
        try expectEqual(home.transport.requestCount, 0, "都不发请求")
    }

    static func failures() throws {
        typealias Response = FakeUsageTransport.Response
        let cases: [(Response?, UsageProblem, Date?)] = [
            (Response(status: 401, body: #"{"error":"invalid"}"#), .login(.notLoggedIn), nil),
            (Response(status: 429, headers: ["Retry-After": "120"], body: ""), .rateLimited,
             fixedNow.addingTimeInterval(120)),
            (Response(status: 403, body: ""), .httpStatus(403), nil),
            (Response(status: 500, body: ""), .httpStatus(500), nil),
            (nil, .networkFailure, nil),
        ]
        for (response, problem, retryAt) in cases {
            let home = try TempHome()
            defer { home.remove() }
            var board = UsageBoard()
            try refreshed(home, body: realBody, into: &board)
            if let response {
                home.transport.respond(toToken: key, response)
            } else {
                home.transport.forget(token: key)
            }
            board.recordReplacing(KimiUsageRefresher(environment: home.environment).refresh(name, now: fixedNow))
            let usage = try unwrap(usage(board), "应有记录")
            try expectEqual(usage.problem, problem)
            try expectEqual(usage.retryAt, retryAt, "\(problem)")
            try expectEqual(usage.sevenDay(now: fixedNow), .remaining(88, tint: .green), "保留上一次的数据：\(problem)")
        }
    }

    static func successReplaces() throws {
        let home = try TempHome()
        defer { home.remove() }
        var board = UsageBoard()
        try refreshed(home, body: body(fiveHour: window(0.8, reset: fiveHourReset),
                                       sevenDay: window(0.5, reset: sevenDayReset)), into: &board)
        try expectEqual(usage(board)?.fiveHour(now: fixedNow), .remaining(20, tint: .red))
        // 滚动窗口：重置时间不变，已用比例下降
        try refreshed(home, body: body(fiveHour: window(0.3, reset: fiveHourReset),
                                       sevenDay: window(0.5, reset: sevenDayReset)), into: &board)
        try expectEqual(usage(board)?.fiveHour(now: fixedNow), .remaining(70, tint: .green), "照新的显示")
        try expectEqual(usage(board)?.sevenDay(now: fixedNow), .remaining(50, tint: .yellow))
        // 这次没给的窗口不再显示旧数字
        try refreshed(home, body: body(fiveHour: window(0.3, reset: fiveHourReset), sevenDay: nil), into: &board)
        try expectEqual(usage(board)?.sevenDay(now: fixedNow), nil)
    }

    static func forgetOnKeyChange() throws {
        let home = try TempHome()
        defer { home.remove() }
        var board = UsageBoard()
        // 旧账号：周窗口已用 90%，重置时间更晚
        try refreshed(home, body: body(fiveHour: window(0.6, reset: fiveHourReset),
                                       sevenDay: window(0.9, reset: "2027-01-20T00:00:00Z")), into: &board)
        try expectEqual(usage(board)?.sevenDay(now: fixedNow), .remaining(10, tint: .red))

        // 新 key 被拒绝（或网络失败）时，不忘掉的话还会显示旧账号的数字
        board.forget(KimiUsageRefresher.account(name))
        try expectEqual(usage(board), nil, "忘掉后没有数据")
        home.transport.respond(toToken: key, FakeUsageTransport.Response(status: 401, body: ""))
        board.recordReplacing(KimiUsageRefresher(environment: home.environment).refresh(name, now: fixedNow))
        try expectEqual(usage(board)?.sevenDay(now: fixedNow), nil, "失败时没有旧账号的数字可显示")
        try refreshed(home, body: realBody, into: &board)
        try expectEqual(usage(board)?.fiveHour(now: fixedNow), .remaining(100, tint: .green))
        try expectEqual(usage(board)?.sevenDay(now: fixedNow), .remaining(88, tint: .green))
    }

    static func multipleAccounts() throws {
        let home = try TempHome()
        defer { home.remove() }
        let other = "sk-kimi-FAKE-other-key-1111"
        try home.kimiKeys.save(key, for: "work")
        try home.kimiKeys.save(other, for: "home")
        home.transport.respond(toToken: key, body: realBody)
        home.transport.respond(toToken: other, body: body(fiveHour: window(0.75, reset: fiveHourReset), sevenDay: nil))
        let refresher = KimiUsageRefresher(environment: home.environment)
        try expectEqual(home.environment.kimiKeys.names(), ["home", "work"], "按名称排序")

        var board = UsageBoard()
        for name in ["home", "work"] { board.recordReplacing(refresher.refresh(name, now: fixedNow)) }
        try expectEqual(home.transport.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                        ["Bearer \(other)", "Bearer \(key)"], "各用各的 key")
        let work = board.usage(for: KimiUsageRefresher.account("work"))
        let homeUsage = board.usage(for: KimiUsageRefresher.account("home"))
        try expectEqual(work?.sevenDay(now: fixedNow), .remaining(88, tint: .green))
        try expectEqual(homeUsage?.fiveHour(now: fixedNow), .remaining(25, tint: .yellow))
        try expectEqual(homeUsage?.sevenDay(now: fixedNow), nil)

        // 删除一个不影响另一个
        try home.kimiKeys.remove("home")
        board.forget(KimiUsageRefresher.account("home"))
        try expectEqual(refresher.refresh("home", now: fixedNow).result, .denied(.notLoggedIn))
        try expectEqual(board.usage(for: KimiUsageRefresher.account("work")), work)

        // 名称规则：字符同档案名，不能重名，没有保留名
        try expectEqual(KimiAccountName.problem("", existing: ["work"]), .empty)
        try expectEqual(KimiAccountName.problem("my key", existing: ["work"]), .malformed)
        try expectEqual(KimiAccountName.problem("-x", existing: ["work"]), .malformed)
        try expectEqual(KimiAccountName.problem("work", existing: ["work"]), .exists)
        try expectEqual(KimiAccountName.problem("default", existing: ["work"]), nil)
        try expectEqual(KimiAccountName.normalizedKey("  sk-x\n"), "sk-x")
        try expectEqual(KimiAccountName.normalizedKey(" \n"), nil)
    }

    static func noKeyLeaks() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.kimiKeys.save(key, for: name)
        let refresher = KimiUsageRefresher(environment: home.environment)
        var board = UsageBoard()
        for response in [FakeUsageTransport.Response(body: realBody),
                         FakeUsageTransport.Response(status: 401, body: "rejected \(key)"),
                         FakeUsageTransport.Response(status: 500, body: key),
                         FakeUsageTransport.Response(body: #"{"usages":"\#(key)"}"#)] {
            home.transport.respond(toToken: key, response)
            let outcome = refresher.refresh(name, now: fixedNow)
            board.record(outcome)
            try expect(!String(describing: outcome).contains(key), "结果里有 key：\(response.status)")
            try expect(!String(describing: board).contains(key), "看板里有 key：\(response.status)")
        }
    }
}
