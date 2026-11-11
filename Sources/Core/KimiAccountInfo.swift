// Kimi Code 账号的套餐名和用户标识（ADR 0007，2026-11-11 补充）：GET https://api.kimi.com/coding/v1/me，
// 头同额度请求，只在用户刷新这个账号时跟在额度请求后面请求（KimiUsageRefresher.refreshAccount，规则同模型列表）。
// 2026-11-11 实测的响应（这里只列字段名，不记任何真实值）：
//   {"user_id", "global_id", "nickname", "avatar", "phone": {"country_code", "number"（打码）}, "status", "region",
//    "user_level", "user_level_name"（套餐名，如 "Moderato"，与 kimi.com 订阅页一致）, "goods_version",
//    "created_time", "last_login_time"}
// 只读 user_level_name（卡片上的套餐标签）和 user_id（认出两个 key 是不是同一个 Kimi 账户，标注"与某某是同一账号"）。
// 昵称、手机号、头像等个人信息不读、不存、不显示。结果只在内存里（UsageModel），不写文件、不进日志。
// 两项都没有（或不是 JSON 对象）就是格式无法识别，算失败；失败时界面保留上一次的。

import Foundation

extension KimiEndpoints {
    static let meEndpoint = URL(string: "https://api.kimi.com/coding/v1/me")!
}

struct KimiAccountInfo: Equatable, Sendable {
    /// 认同一账户用；没有时不参与比较
    let userID: String?
    /// 套餐名；没有时不显示标签
    let planName: String?

    /// 解析 /me 的响应（见文件头）
    static func parse(json data: Data) -> KimiAccountInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            (root[key] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let info = KimiAccountInfo(userID: text("user_id"), planName: text("user_level_name"))
        return info.userID == nil && info.planName == nil ? nil : info
    }

    /// 与 name 属于同一个 Kimi 账户的其他账号名称，按 names 的顺序；没有 user_id 的账号不算
    static func sameAccount(as name: String, names: [String], infos: [String: KimiAccountInfo]) -> [String] {
        guard let id = infos[name]?.userID else { return [] }
        return names.filter { $0 != name && infos[$0]?.userID == id }
    }
}

enum KimiAccountFetchResult: Equatable, Sendable {
    case success(KimiAccountInfo)
    /// 状态码不是 200、网络失败、格式无法识别
    case failure
}

extension KimiUsageRefresher {
    func fetchAccount(key: String) -> KimiAccountFetchResult {
        guard let response = try? environment.transport.send(request(KimiEndpoints.meEndpoint, key: key)),
              response.status == 200,
              let info = KimiAccountInfo.parse(json: response.body) else { return .failure }
        return .success(info)
    }
}
