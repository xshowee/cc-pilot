// Kimi Code 的 Base URL 和模型列表（KimiModels.swift，ADR 0007 2026-11-11 补充）。
// 模型列表：刷新时跟在额度请求后面请求 GET /coding/v1/models，头同额度请求；key 只读一次；额度那边 key 被拒、
// 频率限制、没有 key、网络不通时不请求；只读 id、display_name、context_length、think_efforts。
// 侧边面板：每个 Kimi Code 账号都有一行（与同名的 Claude、ChatGPT 档案互不相干），删除后收起。
// 网络层和 key 存放处都是假的（TempHome.transport、TempHome.kimiKeys）。
//
// tests/fixtures/kimi/models-2026-11-11.json 是 2026-11-11 真实响应的原文（不含任何凭据）。期望值逐项对照原文手写。

import Foundation

final class KimiModelsChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("Base URL 是两个固定地址，模型列表与额度同一个 /coding/v1 下", endpoints),
            Check("真实响应：6 个模型，按原顺序，只取 id、名称、上下文、推理强度", realResponse),
            Check("没有 think_efforts、support 为 false、档位不是字符串时不显示推理强度", effortsMissing),
            Check("data 不是数组就是格式无法识别；没有字符串 id 的条目跳过", malformed),
            Check("上下文：整 MiB、整 KiB 按 1024 换算，其余十进制", contextText),
            Check("刷新：先额度后模型列表，头同额度请求，key 只读一次", refreshBoth),
            Check("额度那边 key 被拒、频率限制、网络不通、没有 key 时不请求模型列表", skipModels),
            Check("模型列表失败不影响额度；额度格式变了仍请求模型列表", independent),
            Check("失败时保留上一次的列表和获取时间", keepLastList),
            Check("侧边面板：Kimi 账号各有一行，不与同名档案相撞；删除后收起", flyoutRows),
        ]
    }

    // MARK: - 夹具

    static let key = KimiUsageRefreshChecks.key
    static let name = KimiUsageRefreshChecks.name
    static let modelsPath = "/coding/v1/models"

    static func realBody() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("tests/fixtures/kimi/models-2026-11-11.json"),
                   encoding: .utf8)
    }

    static func models(_ json: String) -> [KimiModelInfo]? {
        KimiModelsResponse.models(json: Data(json.utf8))
    }

    static func model(_ id: String, _ extra: String) -> String {
        #"{"data":[{"id":"\#(id)"\#(extra)}]}"#
    }

    // MARK: - 检查

    static func endpoints() throws {
        try expectEqual(KimiEndpoints.anthropicBaseURL, "https://api.kimi.com/coding/")
        try expectEqual(KimiEndpoints.openAIBaseURL, "https://api.kimi.com/coding/v1")
        try expectEqual(KimiEndpoints.modelsEndpoint.absoluteString, KimiEndpoints.openAIBaseURL + "/models")
        try expectEqual(KimiUsageRefresher.usageEndpoint.absoluteString, KimiEndpoints.openAIBaseURL + "/usages")
    }

    static func realResponse() throws {
        let list = try unwrap(models(try realBody()), "应能解析")
        let three = ["low", "high", "max"]
        try expectEqual(list, [
            KimiModelInfo(id: "kimi-for-coding", displayName: "K2.8 Preview", contextLength: 1_048_576,
                          efforts: three, defaultEffort: "max"),
            KimiModelInfo(id: "kimi-for-coding-highspeed", displayName: "K2.7 Code Highspeed", contextLength: 262_144,
                          efforts: [], defaultEffort: nil),
            KimiModelInfo(id: "k3-256k", displayName: "K3-256k", contextLength: 262_144,
                          efforts: three, defaultEffort: "high"),
            KimiModelInfo(id: "k3.1-pro-highspeed", displayName: "K3.1 Pro Highspeed 2x Usage Cost",
                          contextLength: 1_048_576, efforts: three, defaultEffort: "high"),
            KimiModelInfo(id: "k3", displayName: "K3", contextLength: 262_144, efforts: three, defaultEffort: "high"),
            KimiModelInfo(id: "k3.1-pro", displayName: "K3.1 Pro", contextLength: 262_144,
                          efforts: three, defaultEffort: "high"),
        ])
        try expectEqual(list.map { $0.contextLength.map(KimiModelInfo.contextText) },
                        ["1M", "256K", "256K", "1M", "256K", "256K"])
    }

    static func effortsMissing() throws {
        // 只有 reasoning（没有 think_efforts）：不拿 reasoning.effort 猜
        let reasoningOnly = model("a", #","reasoning":{"type":"only","effort":{"valid":["low"],"default":"low"}}"#)
        let unsupported = model("a", #","think_efforts":{"support":false,"valid_efforts":["low"],"default_effort":"low"}"#)
        let notStrings = model("a", #","think_efforts":{"support":true,"valid_efforts":["low",1],"default_effort":"low"}"#)
        let empty = model("a", #","think_efforts":{"support":true,"valid_efforts":[]}"#)
        for json in [reasoningOnly, unsupported, notStrings, empty] {
            let info = try unwrap(models(json)?.first, json)
            try expectEqual(info.efforts, [], json)
            try expectEqual(info.defaultEffort, nil, json)
        }
        // 默认档不在可选档里时不显示默认档；没有 support 字段时照常显示
        let odd = model("a", #","think_efforts":{"valid_efforts":["low","high"],"default_effort":"max"}"#)
        let info = try unwrap(models(odd)?.first)
        try expectEqual(info.efforts, ["low", "high"])
        try expectEqual(info.defaultEffort, nil)
    }

    static func malformed() throws {
        for bad in ["{}", "[]", "not json", #"{"data":null}"#, #"{"data":{"id":"a"}}"#] {
            try expectEqual(models(bad), nil, bad)
        }
        try expectEqual(models(#"{"data":[]}"#), [], "空列表不是格式错误")
        let mixed = #"{"data":[{"id":1},{"display_name":"x"},"k3",{"id":""},{"id":"ok","display_name":"","context_length":"8"}]}"#
        try expectEqual(models(mixed), [KimiModelInfo(id: "ok", displayName: nil, contextLength: nil, efforts: [],
                                                      defaultEffort: nil)])
        try expectEqual(models(mixed)?.first?.title, "ok", "没有名称时用 id")
        // 上下文不是正整数时不显示
        for context in ["0", "-1", "1.5", "true"] {
            try expectEqual(models(model("a", #","context_length":\#(context)"#))?.first?.contextLength, nil, context)
        }
    }

    static func contextText() throws {
        try expectEqual(KimiModelInfo.contextText(1_048_576), "1M")
        try expectEqual(KimiModelInfo.contextText(2_097_152), "2M")
        try expectEqual(KimiModelInfo.contextText(262_144), "256K")
        try expectEqual(KimiModelInfo.contextText(131_072), "128K")
        try expectEqual(KimiModelInfo.contextText(200_000), "200.0K")
        try expectEqual(KimiModelInfo.contextText(1_000_000), "1.0M")
        try expectEqual(KimiModelInfo.contextText(500), "500")
    }

    static func refreshBoth() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.kimiKeys.save(key, for: name)
        home.transport.respond(toToken: key, body: KimiUsageRefreshChecks.realBody)
        home.transport.respond(toToken: key, path: modelsPath, .init(body: try realBody()))

        let result = KimiUsageRefresher(environment: home.environment).refreshAccount(name, now: fixedNow)

        try expectEqual(home.kimiKeys.readCount, 1, "key 只读一次")
        try expectEqual(home.transport.requests.map { $0.url?.absoluteString },
                        ["https://api.kimi.com/coding/v1/usages", "https://api.kimi.com/coding/v1/models",
                         "https://api.kimi.com/coding/v1/me"])
        let request = home.transport.requests[1]
        try expectEqual(request.httpMethod, "GET")
        try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        try expectEqual(request.value(forHTTPHeaderField: "User-Agent"), "cc-pilot/\(TempHome.appVersion)")
        try expectEqual(Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }),
                        ["authorization", "user-agent"], "只有这两个头")
        try expect(request.timeoutInterval <= 10, "超时应只有几秒：\(request.timeoutInterval)")
        try expectEqual(result.usage.account, KimiUsageRefresher.account(name))
        try expect(result.usage.result.snapshot != nil, "应拿到额度：\(result.usage.result)")
        guard case .success(let list)? = result.models else { throw CheckFailure(description: "应拿到模型列表：\(String(describing: result.models))") }
        try expectEqual(list.count, 6)
        try expect(!String(describing: result).contains(key), "结果里有 key")
    }

    static func skipModels() throws {
        typealias Response = FakeUsageTransport.Response
        let cases: [(String, Response?, UsageFetchResult)] = [
            ("401", Response(status: 401, body: ""), .unauthorized(.notLoggedIn)),
            ("429", Response(status: 429, headers: ["Retry-After": "60"], body: ""),
             .rateLimited(until: fixedNow.addingTimeInterval(60))),
            ("网络不通", nil, .networkFailure),
        ]
        for (label, response, expected) in cases {
            let home = try TempHome()
            defer { home.remove() }
            try home.kimiKeys.save(key, for: name)
            if let response {
                home.transport.respond(toToken: key, response)
            } else {
                home.transport.failNetwork(toToken: key, path: "/coding/v1/usages")
            }
            home.transport.respond(toToken: key, path: modelsPath, .init(body: try realBody()))
            let result = KimiUsageRefresher(environment: home.environment).refreshAccount(name, now: fixedNow)
            try expectEqual(result.usage.result, expected, label)
            try expectEqual(result.models, nil, "不请求模型列表：\(label)")
            try expectEqual(home.transport.requestCount, 1, label)
        }
        // 没有 key、读不到 key：一个请求都不发
        let home = try TempHome()
        defer { home.remove() }
        let refresher = KimiUsageRefresher(environment: home.environment)
        let none = refresher.refreshAccount(name, now: fixedNow)
        try expectEqual(none.usage.result, .denied(.notLoggedIn))
        try expectEqual(none.models, nil)
        try expectEqual(home.kimiKeys.readCount, 0, "没有 key 时不读")
        try home.kimiKeys.save(key, for: name)
        home.kimiKeys.makeUnreadable()
        let unreadable = refresher.refreshAccount(name, now: fixedNow)
        try expectEqual(unreadable.usage.result, .denied(.accountUnreadable))
        try expectEqual(unreadable.models, nil)
        try expectEqual(home.transport.requestCount, 0)
    }

    static func independent() throws {
        typealias Response = FakeUsageTransport.Response
        // 模型列表失败（各种原因），额度照常
        for (label, response) in [("500", Response(status: 500, body: "")), ("401", Response(status: 401, body: "")),
                                  ("格式", Response(body: #"{"data":"x"}"#)), ("网络", nil)] as [(String, Response?)] {
            let home = try TempHome()
            defer { home.remove() }
            try home.kimiKeys.save(key, for: name)
            home.transport.respond(toToken: key, body: KimiUsageRefreshChecks.realBody)
            if let response {
                home.transport.respond(toToken: key, path: modelsPath, response)
            } else {
                home.transport.failNetwork(toToken: key, path: modelsPath)
            }
            let result = KimiUsageRefresher(environment: home.environment).refreshAccount(name, now: fixedNow)
            try expect(result.usage.result.snapshot != nil, "额度照常：\(label)")
            try expectEqual(result.models, .failure, label)
        }
        // 额度格式无法识别、服务器错误时仍请求模型列表
        for usageResponse in [Response(body: "{}"), Response(status: 500, body: "")] {
            let home = try TempHome()
            defer { home.remove() }
            try home.kimiKeys.save(key, for: name)
            home.transport.respond(toToken: key, usageResponse)
            home.transport.respond(toToken: key, path: modelsPath, .init(body: try realBody()))
            let result = KimiUsageRefresher(environment: home.environment).refreshAccount(name, now: fixedNow)
            try expect(result.usage.result.snapshot == nil, "\(usageResponse.status)")
            guard case .success(let list)? = result.models else { throw CheckFailure(description: "应拿到模型列表") }
            try expectEqual(list.count, 6)
        }
    }

    static func keepLastList() throws {
        let list = try unwrap(models(try realBody()))
        var state = KimiModelList()
        try expectEqual(state.models, nil)
        state.record(.failure, at: fixedNow)
        try expectEqual(state.models, nil, "还没成功过")
        try expect(state.lastFailed, "最近一次失败")
        state.record(.success(list), at: fixedNow)
        try expectEqual(state.models, list)
        try expectEqual(state.fetchedAt, fixedNow)
        try expect(!state.lastFailed, "最近一次成功")
        state.record(.failure, at: fixedNow.addingTimeInterval(600))
        try expectEqual(state.models, list, "保留上一次的列表")
        try expectEqual(state.fetchedAt, fixedNow, "和它的获取时间")
        try expect(state.lastFailed, "最近一次失败")
        state.record(.success([]), at: fixedNow.addingTimeInterval(900))
        try expectEqual(state.models, [], "空列表照新的显示")
        try expect(!state.lastFailed, "最近一次成功")
    }

    static func flyoutRows() throws {
        let kimiWork = StatsFlyoutRow.kimi("work")
        try expect(kimiWork != StatsFlyoutRow(tool: .claudeCode, name: "work"), "不与同名 Claude 档案相撞")
        try expect(kimiWork != StatsFlyoutRow(tool: .chatgpt, name: "work"), "不与同名 ChatGPT 档案相撞")
        try expectEqual(StatsFlyoutRow.rows(claudeCode: [], chatgpt: [], kimi: ["home", "work"]),
                        [.kimi("home"), .kimi("work")], "每个账号都有一行，没刷新过也有")

        var hover = StatsFlyoutHover()
        hover.row(kimiWork, hovering: true)
        try expectEqual(hover.row, kimiWork)
        // 其他段的档案列表变了：Kimi 的行还在，不收起
        hover.rowsChanged(StatsFlyoutRow.rows(claudeCode: [], chatgpt: [], kimi: ["home", "work"]))
        try expectEqual(hover.row, kimiWork)
        // 删除了停着的账号：收起
        hover.rowsChanged(StatsFlyoutRow.rows(claudeCode: [], chatgpt: [], kimi: ["home"]))
        try expectEqual(hover.row, nil)
    }
}
