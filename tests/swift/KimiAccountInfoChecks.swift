// Kimi Code 的 /me（KimiAccountInfo.swift，ADR 0007 2026-11-11 补充）：刷新时跟在额度后面请求，只读 user_level_name
// （套餐标签）和 user_id（认同一账户）；昵称、手机号等个人信息不读。规则同模型列表：额度那边 key 被拒等时不请求。
// 网络层和 key 存放处都是假的（TempHome.transport、TempHome.kimiKeys）。
//
// meBody 的字段与 2026-11-11 真实响应相同，值全部是编的（不记真实的用户标识、昵称、手机号）。

import Foundation

final class KimiAccountInfoChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("响应：只取套餐名和用户标识，昵称、手机号不进结果", parse),
            Check("两项都没有、不是 JSON 对象就是格式无法识别", malformed),
            Check("刷新：请求 /coding/v1/me，头同额度请求；失败不影响额度和模型列表", refresh),
            Check("额度那边 key 被拒时不请求 /me", skipped),
            Check("同一账户：user_id 相同的其他账号，按名称顺序；没有 user_id 的不算", sameAccount),
        ]
    }

    static let key = KimiUsageRefreshChecks.key
    static let name = KimiUsageRefreshChecks.name
    static let nickname = "FAKE-nickname-月球"
    static let phone = "100****0000"

    static func meBody(userID: String = "fake-user-1", plan: String = "Moderato") -> String {
        """
        {"user_id":"\(userID)","global_id":"\(userID)","nickname":"\(nickname)",\
        "avatar":"https://example.invalid/a.png","phone":{"country_code":"86","number":"\(phone)"},\
        "status":"USER_STATUS_NORMAL","region":"REGION_CN","user_level":20,"user_level_name":"\(plan)",\
        "goods_version":1,"created_time":"2026-02-02T02:50:34.969181Z","last_login_time":"2026-11-10T04:30:50.530996Z"}
        """
    }

    static func info(_ json: String) -> KimiAccountInfo? { KimiAccountInfo.parse(json: Data(json.utf8)) }

    static func parse() throws {
        let parsed = try unwrap(info(meBody()))
        try expectEqual(parsed, KimiAccountInfo(userID: "fake-user-1", planName: "Moderato"))
        let text = String(describing: parsed)
        try expect(!text.contains(nickname) && !text.contains(phone), "个人信息不应进结果：\(text)")
        // 只有一项也行；空白当没有
        try expectEqual(info(#"{"user_level_name":" Allegretto "}"#), KimiAccountInfo(userID: nil, planName: "Allegretto"))
        try expectEqual(info(#"{"user_id":"u","user_level_name":""}"#), KimiAccountInfo(userID: "u", planName: nil))
    }

    static func malformed() throws {
        for bad in ["{}", "[]", "not json", #"{"user_id":1,"user_level_name":null}"#, #"{"nickname":"x"}"#,
                    #"{"user_id":"  "}"#] {
            try expectEqual(info(bad), nil, bad)
        }
    }

    static func refresh() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.kimiKeys.save(key, for: name)
        home.transport.respond(toToken: key, body: KimiUsageRefreshChecks.realBody)
        home.transport.respond(toToken: key, path: "/coding/v1/models", .init(body: try KimiModelsChecks.realBody()))
        home.transport.respond(toToken: key, path: "/coding/v1/me", .init(body: meBody()))
        let refresher = KimiUsageRefresher(environment: home.environment)

        let result = refresher.refreshAccount(name, now: fixedNow)
        try expectEqual(result.account, .success(KimiAccountInfo(userID: "fake-user-1", planName: "Moderato")))
        try expectEqual(home.kimiKeys.readCount, 1, "key 只读一次")
        let request = try unwrap(home.transport.requests.last)
        try expectEqual(request.url?.absoluteString, "https://api.kimi.com/coding/v1/me")
        try expectEqual(request.httpMethod, "GET")
        try expectEqual(Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }),
                        ["authorization", "user-agent"], "只有这两个头")
        try expectEqual(request.value(forHTTPHeaderField: "User-Agent"), "cc-pilot/\(TempHome.appVersion)")
        try expect(!String(describing: result).contains(key), "结果里有 key")
        try expect(!String(describing: result).contains(nickname), "结果里有昵称")

        // /me 失败：额度和模型列表照常
        for response in [FakeUsageTransport.Response(status: 500, body: ""), .init(body: "{}")] {
            home.transport.respond(toToken: key, path: "/coding/v1/me", response)
            let failed = refresher.refreshAccount(name, now: fixedNow)
            try expectEqual(failed.account, .failure, "\(response.status)")
            try expect(failed.usage.result.snapshot != nil, "额度照常")
            guard case .success? = failed.models else { throw CheckFailure(description: "模型列表照常") }
        }
    }

    static func skipped() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.kimiKeys.save(key, for: name)
        home.transport.respond(toToken: key, .init(status: 401, body: ""))
        home.transport.respond(toToken: key, path: "/coding/v1/me", .init(body: meBody()))
        let result = KimiUsageRefresher(environment: home.environment).refreshAccount(name, now: fixedNow)
        try expectEqual(result.account, nil)
        try expectEqual(home.transport.requestCount, 1)
    }

    static func sameAccount() throws {
        let infos: [String: KimiAccountInfo] = [
            "a": KimiAccountInfo(userID: "u1", planName: "Moderato"),
            "b": KimiAccountInfo(userID: "u2", planName: nil),
            "c": KimiAccountInfo(userID: "u1", planName: "Moderato"),
            "d": KimiAccountInfo(userID: nil, planName: "Moderato"),
            "e": KimiAccountInfo(userID: "u1", planName: nil),
        ]
        let names = ["a", "b", "c", "d", "e", "f"]
        try expectEqual(KimiAccountInfo.sameAccount(as: "a", names: names, infos: infos), ["c", "e"])
        try expectEqual(KimiAccountInfo.sameAccount(as: "e", names: names, infos: infos), ["a", "c"])
        try expectEqual(KimiAccountInfo.sameAccount(as: "b", names: names, infos: infos), [])
        try expectEqual(KimiAccountInfo.sameAccount(as: "d", names: names, infos: infos), [], "没有 user_id")
        try expectEqual(KimiAccountInfo.sameAccount(as: "f", names: names, infos: infos), [], "还没刷新过")
        // 已删除的账号（不在 names 里）不算
        try expectEqual(KimiAccountInfo.sameAccount(as: "a", names: ["a", "e"], infos: infos), ["e"])
    }
}
