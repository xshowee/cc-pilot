// ticket 12：额度获取失败时如实告诉用户，不猜测数字。
// - 401：按 ticket 10 的规则归为待续期（或需重新登录），不尝试续期；
// - 429 / 403：在 retry-after 规定的时间内不再请求这个账号；没有 retry-after 时等 5 分钟，最长 1 小时；
// - 网络失败或超时：保留上一次成功获取的数据和它的获取时间；
// - 格式无法识别：显示"—"（并提示接口可能已变化）。
// 网络层是假的（TempHome.transport）。期望值来自 spec "额度接口"一节。

import Foundation

final class UsageFailureChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("401：归为待续期，不尝试续期，也不再发别的请求", unauthorized),
            Check("429 / 403：等待到 retry-after 规定的时间；没有时 5 分钟，最长 1 小时", rateLimitDeadline),
            Check("等待期间不再请求这个账号，别的账号照常；时间到了才能再请求", noRequestsWhileWaiting),
            Check("网络失败或超时：保留上一次成功获取的数据和它的获取时间", networkFailureKeepsData),
            Check("格式无法识别：两个窗口都显示—，菜单栏也是—", unrecognizedShowsDash),
            Check("其他状态码：保留上一次的数据，记下状态码", otherStatusKeepsData),
            Check("再次成功后清除失败原因和等待时间", successClearsProblem),
        ]
    }

    /// 一个可以请求额度的账号 solo（令牌 token-solo），以及另一个账号 other（令牌 token-other）
    static func prepare(_ home: TempHome) throws -> (profiles: [Profile], solo: Profile, other: Profile) {
        try home.keychainItem(service: home.makeLoggedInProfile("solo", uuid: "u-solo"), credentialJSON(access: "token-solo"))
        try home.keychainItem(service: home.makeLoggedInProfile("other", uuid: "u-other"),
                              credentialJSON(access: "token-other"))
        home.transport.respond(toToken: "token-solo", body: usageJSON(fiveHour: .used(30, resetsAt: nil)))
        home.transport.respond(toToken: "token-other", body: usageJSON(fiveHour: .used(50, resetsAt: nil)))
        let profiles = ProfileStore(environment: home.environment).listProfiles()
        return (profiles, profiles.first { $0.name == "solo" }!, profiles.first { $0.name == "other" }!)
    }

    static func respond(_ home: TempHome, status: Int, headers: [String: String] = [:], body: String = "{}") {
        home.transport.respond(toToken: "token-solo",
                               FakeUsageTransport.Response(status: status, headers: headers, body: body))
    }

    static func unauthorized() throws {
        let home = try TempHome()
        defer { home.remove() }
        let (profiles, solo, _) = try prepare(home)
        respond(home, status: 401, body: #"{"error":{"type":"authentication_error"}}"#)
        let outcome = UsageRefresher(environment: home.environment).refresh(solo.usageAccount!, in: profiles, now: fixedNow)
        try expectEqual(outcome.result, .unauthorized(.needsRenewal))
        try expectEqual(home.transport.requestCount, 1, "只发了额度请求这一次，没有尝试续期")
        try expectEqual(home.transport.requests.map { $0.url?.absoluteString }, [UsageRefresher.endpoint.absoluteString])
        try expect(home.transport.requests.allSatisfy { $0.httpMethod == "GET" }, "没有发出 POST")

        var board = UsageBoard()
        board.record(outcome)
        try expectEqual(board.usage(for: solo)?.problem, .login(.needsRenewal))
    }

    static func rateLimitDeadline() throws {
        let home = try TempHome()
        defer { home.remove() }
        let (profiles, solo, _) = try prepare(home)
        let refresher = UsageRefresher(environment: home.environment)
        let httpDate = DateFormatter()
        httpDate.locale = Locale(identifier: "en_US_POSIX")
        httpDate.timeZone = TimeZone(identifier: "GMT")
        httpDate.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"

        let cases: [(Int, String?, TimeInterval, String)] = [
            (429, "120", 120, "retry-after 秒数"),
            (403, "90", 90, "403 同样处理"),
            (429, nil, 300, "没有 retry-after：5 分钟"),
            (403, nil, 300, "403 没有 retry-after：5 分钟"),
            (429, "7200", 3600, "最长 1 小时"),
            (429, httpDate.string(from: fixedNow.addingTimeInterval(600)), 600, "retry-after 是 HTTP 日期"),
            (429, httpDate.string(from: fixedNow.addingTimeInterval(86_400)), 3600, "HTTP 日期也最长 1 小时"),
            (429, "soon", 300, "retry-after 认不出：5 分钟"),
            (429, " 45 ", 45, "前后有空白"),
        ]
        for (status, retryAfter, wait, what) in cases {
            respond(home, status: status, headers: retryAfter.map { ["Retry-After": $0] } ?? [:])
            let outcome = refresher.refresh(solo.usageAccount!, in: profiles, now: fixedNow)
            try expectEqual(outcome.result, .rateLimited(until: fixedNow.addingTimeInterval(wait)), what)
        }
    }

    static func noRequestsWhileWaiting() throws {
        let home = try TempHome()
        defer { home.remove() }
        let (profiles, solo, other) = try prepare(home)
        let refresher = UsageRefresher(environment: home.environment)
        var board = UsageBoard()
        // 先成功一次，再被限制频率
        board.record(refresher.refresh(solo.usageAccount!, in: profiles, now: fixedNow))
        respond(home, status: 429, headers: ["retry-after": "120"])
        board.record(refresher.refresh(solo.usageAccount!, in: profiles, now: fixedNow))
        try expectEqual(home.transport.requestCount, 2)

        /// 模拟界面点"刷新全部"：只刷新现在允许请求的账号
        func refreshAll(at now: Date) {
            for account in board.accountsAllowedToRefresh(UsageRefresher.accounts(in: profiles), now: now) {
                board.record(refresher.refresh(account, in: profiles, now: now))
            }
        }
        func requests(_ token: String) -> Int {
            home.transport.requests.filter { $0.value(forHTTPHeaderField: "Authorization") == "Bearer " + token }.count
        }

        let soon = fixedNow.addingTimeInterval(119)
        try expect(board.usage(for: solo)!.isWaiting(now: soon), "等待期间")
        try expectEqual(board.usage(for: solo)?.waitRemaining(now: soon), 1)
        try expectEqual(board.usage(for: solo)?.problem, .rateLimited)
        try expectEqual(board.usage(for: solo)?.snapshot?.fetchedAt, fixedNow, "被限制频率时保留上次的数据")
        refreshAll(at: fixedNow.addingTimeInterval(60))
        refreshAll(at: soon)
        try expectEqual(requests("token-solo"), 2, "等待期间不再请求 solo")
        try expectEqual(requests("token-other"), 2, "别的账号照常请求")
        try expectEqual(board.accountsAllowedToRefresh([solo.usageAccount!], now: soon), [])
        try expect(board.usage(for: other)!.isWaiting(now: soon) == false, "别的账号不用等")

        let due = fixedNow.addingTimeInterval(120)
        try expect(!board.usage(for: solo)!.isWaiting(now: due), "时间到了")
        try expectEqual(board.usage(for: solo)?.waitRemaining(now: due), nil)
        home.transport.respond(toToken: "token-solo", body: usageJSON(fiveHour: .used(10, resetsAt: nil)))
        refreshAll(at: due)
        try expectEqual(requests("token-solo"), 3, "时间到了可以再请求")
        try expectEqual(board.usage(for: solo)?.snapshot?.fiveHour?.remainingPercent, 90)
    }

    static func networkFailureKeepsData() throws {
        let home = try TempHome()
        defer { home.remove() }
        let (profiles, solo, _) = try prepare(home)
        let refresher = UsageRefresher(environment: home.environment)
        var board = UsageBoard()
        board.record(refresher.refresh(solo.usageAccount!, in: profiles, now: fixedNow))

        home.transport.forget(token: "token-solo")
        let later = fixedNow.addingTimeInterval(10 * 60)
        let outcome = refresher.refresh(solo.usageAccount!, in: profiles, now: later)
        try expectEqual(outcome.result, .networkFailure)
        board.record(outcome)
        let usage = board.usage(for: solo)
        try expectEqual(usage?.problem, .networkFailure)
        try expectEqual(usage?.snapshot?.fetchedAt, fixedNow, "标明的是上次成功获取的时间")
        try expectEqual(usage?.fiveHour(now: later), .remaining(70, tint: .plain))
        try expect(usage?.isWaiting(now: later) == false, "网络失败不用等待")
        try expectEqual(board.menuBarSummary(currentProfile: "solo", profiles: profiles, now: later).fiveHour,
                        .remaining(70, tint: .plain))

        // 从没成功过就网络失败：没有数字
        var fresh = UsageBoard()
        fresh.record(outcome)
        try expectEqual(fresh.usage(for: solo)?.problem, .networkFailure)
        try expect(fresh.usage(for: solo)?.fiveHour(now: later) == nil, "没有数据时不显示窗口")
        try expectEqual(fresh.menuBarSummary(currentProfile: "solo", profiles: profiles, now: later).quotaLine(resetText: "Reset"), "—")
    }

    static func unrecognizedShowsDash() throws {
        let home = try TempHome()
        defer { home.remove() }
        let (profiles, solo, _) = try prepare(home)
        let refresher = UsageRefresher(environment: home.environment)
        var board = UsageBoard()
        board.record(refresher.refresh(solo.usageAccount!, in: profiles, now: fixedNow))

        for body in [#"{"something_else":1}"#, "<html>"] {
            respond(home, status: 200, body: body)
            let outcome = refresher.refresh(solo.usageAccount!, in: profiles, now: fixedNow)
            try expectEqual(outcome.result, .unrecognizedFormat)
            board.record(outcome)
            let usage = board.usage(for: solo)
            try expectEqual(usage?.problem, .unrecognizedFormat)
            try expectEqual(usage?.fiveHour(now: fixedNow), .unavailable, "不显示旧数字")
            try expectEqual(usage?.sevenDay(now: fixedNow), .unavailable)
            try expectEqual(board.menuBarSummary(currentProfile: "solo", profiles: profiles, now: fixedNow).quotaLine(resetText: "Reset"), "—")
        }
    }

    static func otherStatusKeepsData() throws {
        let home = try TempHome()
        defer { home.remove() }
        let (profiles, solo, _) = try prepare(home)
        let refresher = UsageRefresher(environment: home.environment)
        var board = UsageBoard()
        board.record(refresher.refresh(solo.usageAccount!, in: profiles, now: fixedNow))
        respond(home, status: 500, body: usageJSON())
        let outcome = refresher.refresh(solo.usageAccount!, in: profiles, now: fixedNow)
        try expectEqual(outcome.result, .httpStatus(500))
        board.record(outcome)
        try expectEqual(board.usage(for: solo)?.problem, .httpStatus(500))
        try expectEqual(board.usage(for: solo)?.fiveHour(now: fixedNow), .remaining(70, tint: .plain))
        try expect(board.usage(for: solo)?.isWaiting(now: fixedNow) == false, "500 不用等待")
    }

    static func successClearsProblem() throws {
        let home = try TempHome()
        defer { home.remove() }
        let (profiles, solo, _) = try prepare(home)
        let refresher = UsageRefresher(environment: home.environment)
        var board = UsageBoard()
        respond(home, status: 200, body: "{}")
        board.record(refresher.refresh(solo.usageAccount!, in: profiles, now: fixedNow))
        try expectEqual(board.usage(for: solo)?.problem, .unrecognizedFormat)

        home.transport.respond(toToken: "token-solo", body: usageJSON(fiveHour: .used(30, resetsAt: nil)))
        let later = fixedNow.addingTimeInterval(400)
        board.record(refresher.refresh(solo.usageAccount!, in: profiles, now: later))
        let usage = board.usage(for: solo)
        try expectEqual(usage?.problem, nil)
        try expectEqual(usage?.retryAt, nil)
        try expectEqual(usage?.snapshot?.fetchedAt, later)
        try expectEqual(usage?.fiveHour(now: later), .remaining(70, tint: .plain))
    }
}
