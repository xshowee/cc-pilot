// 刷新 Antigravity 额度（AntigravityRefresher，spec "数据来源""解析规则""刷新"，接缝 1）。
// 一次刷新 = 找 language server → 找端口 → GetUserStatus → RetrieveUserQuotaSummary。
// 进程查询和网络层都是假的（TempHome.antigravityProcesses、TempHome.transport）：绝不查看真实进程、
// 绝不调用真实的 Antigravity 本地接口。
//
// 真实响应是 tests/fixtures/antigravity/ 里 2026-11-14 抓取的原文（个人信息已替换），检查里的"现在"是抓取时刻
// capturedAt（不是全局的 fixedNow：夹具的重置时间相对抓取时刻才是未来）。
// 期望的剩余百分比手算：remainingFraction × 100 向下取整（0.8601882 → 86）。

import Foundation

final class AntigravityRefreshChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("找不到 language server：不读参数、不发请求，结果是 App 没在运行", appNotRunning),
            Check("请求：POST 两个 RPC，带 csrf 头与 JSON，GetUserStatus 体为 {}，额度体 forceRefresh: true", requests),
            Check("端口：逐个试 GetUserStatus，HTTPS 端口的 400 跳过，取第一个 200 的，额度用同一端口", portSelection),
            Check("真实响应：邮箱、套餐取对；两组各两个窗口按接口顺序，剩余按 remainingFraction 手算", realResponse),
            Check("剩余向下取整，不受浮点误差影响：0.29 → 29、1 → 100、0 → 0、超出 0–1 的夹到范围内", rounding),
            Check("remainingFraction 缺失 + 未来 resetTime → 0%；都缺或重置时间已过 → 没有数字；disabled → 0%", missingFraction),
            Check("多个 language server：逐个试，取第一个拿到 GetUserStatus 200 的", multipleServers),
            Check("有进程但读不出 token、没有端口、端口都不通：失败，不当作 App 没在运行", noUsableServer),
            Check("GetUserStatus 没有 email → 未登录，不请求额度；不是 JSON 或没有 userStatus → 格式无法识别", notSignedIn),
            Check("额度请求非 200、网络失败：失败原因带上已读到的邮箱", quotaFailures),
            Check("未知 window、没有 groups、组没有 buckets 等 → 格式无法识别，带上邮箱", unrecognizedFormat),
            Check("Pro 形态 1：多于两组、组内只有一个周窗口，原样保留，套餐取对", proSeparateGroups),
            Check("Pro 形态 2：组内两个周窗口，原样保留，各带 bucketId", proExtraBucket),
            Check("组名按 displayName 认（不分大小写），其余照搬；模型列表前缀对不上原样、没有 description 为空", groupNames),
            Check("csrf token 不出现在结果和失败原因里", noTokenLeaks),
        ]
    }

    // MARK: - 夹具

    /// 抓取夹具的时刻
    static let capturedAt = ISO8601DateFormatter().date(from: "2026-11-14T16:17:12Z")!
    /// 假的 csrf token（不是真实的）
    static let token = "FAKE-csrf-0000-check"

    static let servicePath = "/exa.language_server_pb.LanguageServerService/"
    static let statusPath = servicePath + "GetUserStatus"
    static let quotaPath = servicePath + "RetrieveUserQuotaSummary"

    static func fixture(_ name: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("tests/fixtures/antigravity/\(name).json"), encoding: .utf8)
    }

    static let httpsPort = 61882
    static let httpPort = 61883
    static let otherPort = 61904

    /// 摆出实测的形态：一个 language server、三个端口（HTTPS、HTTP、需要别的鉴权），HTTP 端口返回 status / quota
    static func serve(_ home: TempHome, status: FakeUsageTransport.Response? = nil,
                      quota: FakeUsageTransport.Response? = nil) throws {
        home.antigravityProcesses.run(pid: 4242, token: token, ports: [httpsPort, httpPort, otherPort])
        let https = FakeUsageTransport.Response(status: 400, body: "Client sent an HTTP request to an HTTPS server.\n")
        home.transport.respond(toPort: httpsPort, path: statusPath, https)
        home.transport.respond(toPort: httpsPort, path: quotaPath, https)
        home.transport.respond(toPort: httpPort, path: statusPath,
                               try status ?? .init(body: fixture("get-user-status-ultra-2026-11-14")))
        home.transport.respond(toPort: httpPort, path: quotaPath,
                               try quota ?? .init(body: fixture("retrieve-user-quota-summary-ultra-2026-11-14")))
    }

    static func success(_ result: AntigravityRefreshResult) throws -> AntigravityAccountQuota {
        guard case .success(let quota) = result else { throw CheckFailure(description: "应成功：\(result)") }
        return quota
    }

    static let iso = ISO8601DateFormatter()

    static func refresh(_ home: TempHome, now: Date = capturedAt) -> AntigravityRefreshResult {
        AntigravityRefresher(environment: home.environment).refresh(now: now)
    }

    /// 一组一桶的额度响应
    static func quotaBody(_ bucket: [String: Any]) -> String {
        let group: [String: Any] = ["displayName": "Gemini Models", "buckets": [bucket]]
        let data = try! JSONSerialization.data(withJSONObject: ["response": ["groups": [group]]], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// 刷新一次，返回唯一一个桶此刻的显示和重置时间
    static func onlyBucket(_ bucket: [String: Any]) throws -> (UsageReading, Date?) {
        let home = try TempHome()
        defer { home.remove() }
        try serve(home, quota: .init(body: quotaBody(bucket)))
        let quota = try success(refresh(home))
        let only = try unwrap(quota.groups.first?.buckets.first, "应有一个桶")
        return (UsageReading(only.usage, fetchedAt: quota.fetchedAt, now: capturedAt), only.usage?.resetsAt)
    }

    static let futureReset = "2026-11-14T18:00:00Z"
    static let pastReset = "2026-11-14T16:00:00Z"

    // MARK: - 检查

    static func appNotRunning() throws {
        let home = try TempHome()
        defer { home.remove() }

        try expectEqual(refresh(home), .appNotRunning)
        try expectEqual(home.antigravityProcesses.listCalls, 1, "列一次进程")
        try expectEqual(home.antigravityProcesses.tokenReads, [], "不读参数")
        try expectEqual(home.transport.requestCount, 0, "不发请求")
    }

    static func requests() throws {
        let home = try TempHome()
        defer { home.remove() }
        try serve(home)

        _ = try success(refresh(home))

        let sent = home.transport.requests
        try expectEqual(sent.map { $0.url?.absoluteString ?? "" },
                        ["http://127.0.0.1:\(httpsPort)\(statusPath)", "http://127.0.0.1:\(httpPort)\(statusPath)",
                         "http://127.0.0.1:\(httpPort)\(quotaPath)"])
        for request in sent {
            try expectEqual(request.httpMethod, "POST")
            try expectEqual(request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token"), token)
            try expectEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "不带 Authorization")
        }
        func body(_ request: URLRequest) throws -> NSDictionary {
            try unwrap(try JSONSerialization.jsonObject(with: unwrap(request.httpBody, "没有请求体")) as? NSDictionary)
        }
        try expectEqual(try body(sent[1]), [:] as NSDictionary, "GetUserStatus 体")
        try expectEqual(try body(sent[2]), ["forceRefresh": true] as NSDictionary, "额度请求体")
        try expect(sent[0].timeoutInterval <= 3, "探测端口用短超时：\(sent[0].timeoutInterval)")
        try expect(sent[2].timeoutInterval <= 10, "额度请求超时只有几秒：\(sent[2].timeoutInterval)")
    }

    static func portSelection() throws {
        let home = try TempHome()
        defer { home.remove() }
        // 第一个端口连不上（没有准备响应），第二个是 HTTPS 端口（400），第三个才是 HTTP 端口，第四个不再试
        home.antigravityProcesses.run(pid: 7, token: token, ports: [50000, httpsPort, httpPort, otherPort])
        home.transport.respond(toPort: httpsPort, path: statusPath, .init(status: 400, body: "Client sent an HTTP request"))
        home.transport.respond(toPort: httpPort, path: statusPath, .init(body: try fixture("get-user-status-ultra-2026-11-14")))
        home.transport.respond(toPort: httpPort, path: quotaPath,
                               .init(body: try fixture("retrieve-user-quota-summary-ultra-2026-11-14")))
        home.transport.respond(toPort: otherPort, path: statusPath, .init(body: "{}"))

        _ = try success(refresh(home))
        try expectEqual(home.transport.requests.map { $0.url?.port ?? 0 }, [50000, httpsPort, httpPort, httpPort])
    }

    static func realResponse() throws {
        let home = try TempHome()
        defer { home.remove() }
        try serve(home)

        let quota = try success(refresh(home))

        try expectEqual(quota.email, "ultra@example.com")
        try expectEqual(quota.tierName, "Google AI Ultra")
        try expectEqual(quota.tierId, "g1-ultra-lite-tier")
        try expectEqual(quota.fetchedAt, capturedAt)
        try expectEqual(quota.groups.map(\.displayName), ["Gemini Models", "Claude and GPT models"])
        try expectEqual(quota.groups.map(\.kind), [.gemini, .thirdParty])
        try expectEqual(quota.groups[0].models, ["Gemini 4 Carbon", "Gemini 4 Argon", "Gemini 4 Hydrogen",
                                                 "Orchestrator (Carbon)", "Orchestrator (Argon)", "Gemini 3.8 Flash"])
        try expectEqual(quota.groups[1].models, ["Claude Opus 5.5", "Claude Sonnet 5.5", "GPT-OSS 120B"])

        struct Row: Equatable {
            let id: String?, name: String?, window: AntigravityQuotaBucket.Window, reading: UsageReading, reset: Date?
        }
        func rows(_ group: AntigravityQuotaGroup) -> [Row] {
            group.buckets.map {
                Row(id: $0.bucketId, name: $0.displayName, window: $0.window,
                    reading: UsageReading($0.usage, fetchedAt: quota.fetchedAt, now: capturedAt), reset: $0.usage?.resetsAt)
            }
        }
        // 0.8601882 → 86；0.89397126 → 89；0.89619607 → 89；0.79239213 → 79
        try expectEqual(rows(quota.groups[0]), [
            Row(id: "gemini-weekly", name: "Weekly Limit Remaining", window: .weekly,
                reading: .remaining(86, tint: .green), reset: iso.date(from: "2026-11-21T10:12:34Z")),
            Row(id: "gemini-5h", name: "Five Hour Limit Remaining", window: .fiveHour,
                reading: .remaining(89, tint: .green), reset: iso.date(from: "2026-11-14T20:12:34Z")),
        ])
        try expectEqual(rows(quota.groups[1]), [
            Row(id: "3p-weekly", name: "Weekly Limit Remaining", window: .weekly,
                reading: .remaining(89, tint: .green), reset: iso.date(from: "2026-11-21T12:16:09Z")),
            Row(id: "3p-5h", name: "Five Hour Limit Remaining", window: .fiveHour,
                reading: .remaining(79, tint: .green), reset: iso.date(from: "2026-11-14T17:16:09Z")),
        ])
    }

    static func rounding() throws {
        for (fraction, expected) in [(0.29, 29), (0.57, 57), (1.0, 100), (0.0, 0), (0.999, 99), (0.0001, 0),
                                     (1.5, 100), (-0.2, 0)] as [(Double, Int)] {
            let (reading, _) = try onlyBucket(["bucketId": "gemini-5h", "window": "5h",
                                               "remainingFraction": fraction, "resetTime": futureReset])
            guard case .remaining(let percent, _) = reading else {
                throw CheckFailure(description: "\(fraction) 应有数字：\(reading)")
            }
            try expectEqual(percent, expected, "remainingFraction \(fraction)")
        }
    }

    static func missingFraction() throws {
        let (exhausted, reset) = try onlyBucket(["bucketId": "gemini-weekly", "window": "weekly", "resetTime": futureReset])
        try expectEqual(exhausted, .remaining(0, tint: .red), "proto3 省略了零值")
        try expectEqual(reset, iso.date(from: futureReset))
        try expectEqual(try onlyBucket(["bucketId": "gemini-weekly", "window": "weekly"]).0, .unavailable, "都缺")
        try expectEqual(try onlyBucket(["bucketId": "gemini-weekly", "window": "weekly", "resetTime": pastReset]).0,
                        .unavailable, "重置时间已过，不知道现在剩多少")
        try expectEqual(try onlyBucket(["bucketId": "gemini-weekly", "window": "weekly", "disabled": true,
                                        "remainingFraction": 0.8, "resetTime": futureReset]).0,
                        .remaining(0, tint: .red), "disabled 的桶当 0%")
        try expectEqual(try onlyBucket(["bucketId": "gemini-weekly", "window": "weekly", "disabled": false,
                                        "remainingFraction": 0.8, "resetTime": futureReset]).0,
                        .remaining(80, tint: .green), "disabled: false 照常")
    }

    static let proStatus = #"{"userStatus":{"email":"pro@example.com","userTier":{"id":"g1-pro-tier","name":"Google AI Pro"}}}"#

    static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func bucket(_ id: String, _ window: String, _ fraction: Double, name: String? = nil) -> [String: Any] {
        var bucket: [String: Any] = ["bucketId": id, "window": window, "remainingFraction": fraction,
                                     "resetTime": futureReset]
        if let name { bucket["displayName"] = name }
        return bucket
    }

    static func group(_ name: String, description: String? = nil, _ buckets: [[String: Any]]) -> [String: Any] {
        var group: [String: Any] = ["displayName": name, "buckets": buckets]
        if let description { group["description"] = description }
        return group
    }

    static func quotaJSON(_ groups: [[String: Any]]) -> String {
        json(["response": ["groups": groups]])
    }

    struct BucketSummary: Equatable {
        let id: String?, name: String?, window: AntigravityQuotaBucket.Window, remaining: Int?
        init(_ id: String?, _ name: String?, _ window: AntigravityQuotaBucket.Window, _ remaining: Int?) {
            self.id = id
            self.name = name
            self.window = window
            self.remaining = remaining
        }
    }

    struct GroupSummary: Equatable {
        let name: String, kind: AntigravityQuotaGroup.Kind, models: [String], buckets: [BucketSummary]
        init(_ name: String, _ kind: AntigravityQuotaGroup.Kind, _ models: [String], _ buckets: [BucketSummary]) {
            self.name = name
            self.kind = kind
            self.models = models
            self.buckets = buckets
        }
    }

    static func summary(_ quota: AntigravityAccountQuota) -> [GroupSummary] {
        quota.groups.map { group in
            GroupSummary(group.displayName, group.kind, group.models, group.buckets.map {
                BucketSummary($0.bucketId, $0.displayName, $0.window, $0.usage?.remainingPercent)
            })
        }
    }

    static func multipleServers() throws {
        let home = try TempHome()
        defer { home.remove() }
        // 第一个窗口的进程读不出参数；第二个的端口返回 401；第三个能用；第四个不再碰
        let unreadable = home.antigravityProcesses.run(pid: 10, token: nil, ports: [40000])
        let dead = home.antigravityProcesses.run(pid: 11, token: "dead-token", ports: [40001])
        let good = home.antigravityProcesses.run(pid: 12, token: token, ports: [httpPort])
        let spare = home.antigravityProcesses.run(pid: 13, token: "spare-token", ports: [40003])
        home.transport.respond(toPort: 40001, path: statusPath, .init(status: 401, body: "bad csrf"))
        home.transport.respond(toPort: httpPort, path: statusPath, .init(body: try fixture("get-user-status-ultra-2026-11-14")))
        home.transport.respond(toPort: httpPort, path: quotaPath,
                               .init(body: try fixture("retrieve-user-quota-summary-ultra-2026-11-14")))

        try expectEqual(try success(refresh(home)).email, "ultra@example.com")
        try expectEqual(home.antigravityProcesses.tokenReads, [unreadable, dead, good])
        try expectEqual(home.antigravityProcesses.portQueries, [dead, good], "读不出 token 的不列端口")
        try expect(!home.antigravityProcesses.tokenReads.contains(spare), "拿到 200 后不再试别的进程")
        let sent = home.transport.requests
        try expectEqual(sent.map { $0.url?.port ?? 0 }, [40001, httpPort, httpPort])
        try expectEqual(sent.map { $0.value(forHTTPHeaderField: "X-Codeium-Csrf-Token") ?? "" },
                        ["dead-token", token, token], "每个进程用自己的 token")
    }

    static func noUsableServer() throws {
        do {
            let home = try TempHome()
            defer { home.remove() }
            home.antigravityProcesses.run(pid: 10, token: nil, ports: [httpPort])
            try expectEqual(refresh(home), .failed(email: nil, reason: .processUnreadable))
            try expectEqual(home.transport.requestCount, 0)
        }
        do {
            let home = try TempHome()
            defer { home.remove() }
            home.antigravityProcesses.run(pid: 10, token: token, ports: [])
            try expectEqual(refresh(home), .failed(email: nil, reason: .noReachablePort), "没有端口")
        }
        do {
            let home = try TempHome()
            defer { home.remove() }
            home.antigravityProcesses.run(pid: 10, token: token, ports: [httpsPort, httpPort])
            home.transport.respond(toPort: httpsPort, path: statusPath, .init(status: 400, body: "https"))
            home.transport.respond(toPort: httpPort, path: statusPath, .init(status: 500, body: "boom"))
            try expectEqual(refresh(home), .failed(email: nil, reason: .noReachablePort), "端口都非 200")
            try expectEqual(home.transport.requestCount, 2, "不请求额度")
        }
    }

    static func notSignedIn() throws {
        for body in [#"{"userStatus":{"name":"x"}}"#, #"{"userStatus":{"email":""}}"#, #"{"userStatus":{}}"#] {
            let home = try TempHome()
            defer { home.remove() }
            try serve(home, status: .init(body: body))
            try expectEqual(refresh(home), .notSignedIn, body)
            try expect(!home.transport.requests.contains { $0.url?.path == quotaPath }, "未登录不请求额度：\(body)")
        }
        for body in ["not json", "[]", "{}", #"{"userStatus":"x"}"#] {
            let home = try TempHome()
            defer { home.remove() }
            try serve(home, status: .init(body: body))
            try expectEqual(refresh(home), .unrecognizedFormat(email: nil), body)
            try expect(!home.transport.requests.contains { $0.url?.path == quotaPath }, "不请求额度：\(body)")
        }
    }

    static func quotaFailures() throws {
        for status in [500, 401, 403, 404] {
            let home = try TempHome()
            defer { home.remove() }
            try serve(home, quota: .init(status: status, body: "nope"))
            try expectEqual(refresh(home), .failed(email: "ultra@example.com", reason: .httpStatus(status)))
        }
        let home = try TempHome()
        defer { home.remove() }
        try serve(home, quota: .init(status: -1, body: ""))
        try expectEqual(refresh(home), .failed(email: "ultra@example.com", reason: .networkFailure))
    }

    static func unrecognizedFormat() throws {
        let gemini = bucket("gemini-5h", "5h", 0.5)
        let bad = [
            quotaJSON([group("Gemini Models", [bucket("gemini-daily", "daily", 0.5)])]),
            quotaJSON([group("Gemini Models", [gemini, bucket("gemini-x", "WEEKLY", 0.5)])]),
            quotaJSON([group("Gemini Models", [["bucketId": "gemini-5h", "remainingFraction": 0.5]])]),
            quotaJSON([["displayName": "Gemini Models"]]),
            quotaJSON([["buckets": [gemini]]]),
            json(["response": [String: Any]()]),
            // proto3 的 JSON 省略空的 repeated 字段，空数组与没有 groups 同样对待
            quotaJSON([]),
            json(["response": ["groups": "x"]]),
            json(["groups": [group("Gemini Models", [gemini])]]),
            "{}", "not json",
        ]
        for body in bad {
            let home = try TempHome()
            defer { home.remove() }
            try serve(home, quota: .init(body: body))
            try expectEqual(refresh(home), .unrecognizedFormat(email: "ultra@example.com"), body)
        }
    }

    static func proSeparateGroups() throws {
        let home = try TempHome()
        defer { home.remove() }
        let argonDescription = "For paid Pro plans, Argon quota is separate. Usage of Argon models counts against it."
        try serve(home, status: .init(body: proStatus), quota: .init(body: quotaJSON([
            group("Gemini Models", description: "Models within this group: Gemini Flash, Gemini Pro",
                  [bucket("gemini-5h", "5h", 0.95), bucket("gemini-weekly", "weekly", 0.9)]),
            group("Gemini 4 Argon", description: argonDescription,
                  [bucket("gemini-argon-wtu-weekly", "weekly", 0.35, name: "Gemini 4 Argon Weekly Limit")]),
            group("Gemini 4 Carbon", [bucket("carbon-weekly", "weekly", 0.4)]),
            group("Claude and GPT models", [bucket("3p-5h", "5h", 1), bucket("3p-weekly", "weekly", 0.8)]),
        ])))

        let quota = try success(refresh(home))
        try expectEqual(quota.email, "pro@example.com")
        try expectEqual(quota.tierName, "Google AI Pro")
        try expectEqual(quota.tierId, "g1-pro-tier")
        try expectEqual(summary(quota), [
            GroupSummary("Gemini Models", .gemini, ["Gemini Flash", "Gemini Pro"],
                         [BucketSummary("gemini-5h", nil, .fiveHour, 95), BucketSummary("gemini-weekly", nil, .weekly, 90)]),
            // bucketId 以 gemini- 开头，但组名不是 Gemini Models：照搬原名（facts.md "对 spec 规则的修正"）
            GroupSummary("Gemini 4 Argon", .other, [argonDescription],
                         [BucketSummary("gemini-argon-wtu-weekly", "Gemini 4 Argon Weekly Limit", .weekly, 35)]),
            GroupSummary("Gemini 4 Carbon", .other, [], [BucketSummary("carbon-weekly", nil, .weekly, 40)]),
            GroupSummary("Claude and GPT models", .thirdParty, [],
                         [BucketSummary("3p-5h", nil, .fiveHour, 100), BucketSummary("3p-weekly", nil, .weekly, 80)]),
        ])
    }

    static func proExtraBucket() throws {
        let home = try TempHome()
        defer { home.remove() }
        try serve(home, status: .init(body: proStatus), quota: .init(body: quotaJSON([
            group("Gemini Models", [bucket("gemini-5h", "5h", 1), bucket("gemini-weekly", "weekly", 0.88),
                                    bucket("argon-weekly", "weekly", 0.42)]),
        ])))

        try expectEqual(summary(try success(refresh(home))), [
            GroupSummary("Gemini Models", .gemini, [], [BucketSummary("gemini-5h", nil, .fiveHour, 100),
                                                        BucketSummary("gemini-weekly", nil, .weekly, 88),
                                                        BucketSummary("argon-weekly", nil, .weekly, 42)]),
        ])
    }

    static func groupNames() throws {
        let home = try TempHome()
        defer { home.remove() }
        let b = [bucket("x-5h", "5h", 0.5)]
        let row = [BucketSummary("x-5h", nil, .fiveHour, 50)]
        try serve(home, quota: .init(body: quotaJSON([
            group("GEMINI MODELS", description: "Models within this group:  A ,B,, C ", b),
            group("claude and gpt Models", description: "Models within this group:", b),
            group("Gemini Models Preview", description: "models within this group: A, B", b),
            group("Claude", description: "", b),
        ])))

        try expectEqual(summary(try success(refresh(home))), [
            GroupSummary("GEMINI MODELS", .gemini, ["A", "B", "C"], row),
            GroupSummary("claude and gpt Models", .thirdParty, [], row),
            GroupSummary("Gemini Models Preview", .other, ["models within this group: A, B"], row),
            GroupSummary("Claude", .other, [], row),
        ])
    }

    static func noTokenLeaks() throws {
        let leaky = "rejected \(token)"
        let cases: [(status: FakeUsageTransport.Response?, quota: FakeUsageTransport.Response?)] = [
            (nil, nil),
            (nil, .init(status: 500, body: leaky)),
            (nil, .init(status: -1, body: "")),
            (nil, .init(body: json(["response": ["groups": [group("x", [bucket("y", leaky, 0.5)])]]]))),
            (.init(body: #"{"userStatus":{"name":"\#(token)"}}"#), nil),
            (.init(body: leaky), nil),
            (.init(status: 403, body: leaky), nil),
        ]
        for (status, quota) in cases {
            let home = try TempHome()
            defer { home.remove() }
            try serve(home, status: status, quota: quota)
            let result = refresh(home)
            try expect(!(String(describing: result) + String(reflecting: result)).contains(token), "结果里有 token：\(result)")
        }
    }
}
