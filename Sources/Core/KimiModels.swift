// Kimi Code 的 Base URL 和可用模型列表（ADR 0007，2026-11-11 补充）：鼠标停在 Kimi Code 卡片上时，侧边面板显示
// 两个 Base URL（可复制）和这个账号的 key 能用的模型（名称、id、上下文、推理强度）。
//
// Base URL 是固定值，不用请求：Anthropic 兼容的给 Claude Code 等用（客户端自己拼 /v1/messages），
// OpenAI 兼容的给其他客户端用（拼 /chat/completions）。2026-11-11 实测：不带 key 时这两个地址下的
// /v1/messages、/chat/completions、/models 都返回 401，随便编的路径返回 404。
//
// 模型列表：GET https://api.kimi.com/coding/v1/models，头同额度请求（只有 Authorization 和 User-Agent）。
// 只在用户刷新这个账号时，跟在额度请求后面请求（KimiUsageRefresher.refreshAccount，key 只读一次）；
// 额度那边是 key 被拒、频率限制、没有 key 或网络不通时不再请求。结果只在内存里（UsageModel），不写文件。
// 接口同样没有官方文档；下面的格式是 2026-11-11 实测（OpenAI 风格的分页列表，has_more 为 false）：
//   {"object": "list", "has_more": false, "data": [
//     {"id": "kimi-for-coding", "display_name": "K2.8 Preview", "context_length": 1048576,
//      "think_efforts": {"support": true, "valid_efforts": ["low", "high", "max"], "default_effort": "max"},
//      "reasoning": {...}, "limit": {"context": 1048576}, "supports_*": ..., "modalities": {...}, ...}, ...]}
// 只读 id、display_name、context_length、think_efforts.valid_efforts / default_effort。其余字段（reasoning、limit、
// supports_*、modalities）与这几项重复或含义没有说明，不读、不猜。没有 think_efforts（或 support 为 false、
// valid_efforts 不是字符串数组）的模型不显示推理强度。不翻页（has_more 不看）：实测一次就返回了全部。
// data 不是数组就是格式无法识别；没有字符串 id 的条目跳过。

import Foundation

enum KimiEndpoints {
    /// Anthropic 兼容（ANTHROPIC_BASE_URL）
    static let anthropicBaseURL = "https://api.kimi.com/coding/"
    /// OpenAI 兼容
    static let openAIBaseURL = "https://api.kimi.com/coding/v1"
    static let modelsEndpoint = URL(string: "https://api.kimi.com/coding/v1/models")!
}

/// 一个可用模型（只取文件头说的几项）
struct KimiModelInfo: Equatable, Sendable {
    let id: String
    /// 没有时界面用 id
    let displayName: String?
    /// 上下文长度（token）；没有时不显示
    let contextLength: Int?
    /// 可选的推理强度，按响应里的顺序；不显示时为空
    let efforts: [String]
    /// 默认的推理强度；不在 efforts 里时不显示
    let defaultEffort: String?

    var title: String { displayName ?? id }

    /// 上下文长度的显示：整 MiB、整 KiB 时按 1024 换算（1048576 → 1M、262144 → 256K，与 Kimi 自己的叫法一致），
    /// 否则按十进制紧凑写法（200000 → 200.0K，同 TokenUsageDisplay.compact）
    static func contextText(_ tokens: Int) -> String {
        let mebi = 1024 * 1024
        if tokens > 0, tokens % mebi == 0 { return "\(tokens / mebi)M" }
        if tokens > 0, tokens % 1024 == 0 { return "\(tokens / 1024)K" }
        return TokenUsageDisplay.compact(tokens)
    }
}

/// 一次模型列表请求的结果
enum KimiModelsFetchResult: Equatable, Sendable {
    case success([KimiModelInfo])
    /// 状态码不是 200、网络失败、格式无法识别：界面只说"获取失败"，不细分
    case failure
}

/// 一个账号的模型列表在界面上的状态。失败时保留上一次的列表和它的获取时间
struct KimiModelList: Equatable, Sendable {
    /// 最近一次成功获取的列表；还没成功过时为 nil
    private(set) var models: [KimiModelInfo]?
    private(set) var fetchedAt: Date?
    /// 最近一次请求失败了
    private(set) var lastFailed = false

    init() {}

    mutating func record(_ result: KimiModelsFetchResult, at date: Date) {
        switch result {
        case .success(let list):
            models = list
            fetchedAt = date
            lastFailed = false
        case .failure:
            lastFailed = true
        }
    }
}

/// /coding/v1/models 的响应（见文件头）
enum KimiModelsResponse {
    static func models(json data: Data) -> [KimiModelInfo]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["data"] as? [Any] else { return nil }
        return entries.compactMap { entry -> KimiModelInfo? in
            guard let object = entry as? [String: Any], let id = object["id"] as? String, !id.isEmpty else { return nil }
            let name = (object["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let context = UsageSnapshot.number(object["context_length"]).flatMap { $0 > 0 ? Int(exactly: $0) : nil }
            let (efforts, preferred) = efforts(object["think_efforts"])
            return KimiModelInfo(id: id, displayName: name, contextLength: context, efforts: efforts,
                                 defaultEffort: preferred)
        }
    }

    private static func efforts(_ value: Any?) -> ([String], String?) {
        guard let object = value as? [String: Any], object["support"] as? Bool != false,
              let list = object["valid_efforts"] as? [Any] else { return ([], nil) }
        let efforts = list.compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard efforts.count == list.count, !efforts.isEmpty else { return ([], nil) }
        let preferred = (object["default_effort"] as? String).flatMap { efforts.contains($0) ? $0 : nil }
        return (efforts, preferred)
    }
}

/// 用户刷新一个 Kimi Code 账号的全部结果
struct KimiRefreshResult: Equatable, Sendable {
    let usage: UsageRefreshOutcome
    /// 模型列表；没有请求时为 nil
    var models: KimiModelsFetchResult? = nil
    /// 套餐名和用户标识（/me，KimiAccountInfo.swift）；没有请求时为 nil
    var account: KimiAccountFetchResult? = nil
}

extension KimiUsageRefresher {
    /// 用户刷新一个账号：先请求额度，再请求模型列表和 /me（见文件头）。key 只读一次（每读一次都可能弹出钥匙串授权）
    func refreshAccount(_ name: String, now: Date = Date()) -> KimiRefreshResult {
        let key: String
        switch readKey(name) {
        case .success(let read): key = read
        case .failure(let denied):
            return KimiRefreshResult(usage: UsageRefreshOutcome(account: Self.account(name), result: denied.result))
        }
        let usage = fetchUsage(key: key, now: now)
        let outcome = UsageRefreshOutcome(account: Self.account(name), result: usage)
        guard Self.shouldFetchModels(after: usage) else { return KimiRefreshResult(usage: outcome) }
        return KimiRefreshResult(usage: outcome, models: fetchModels(key: key), account: fetchAccount(key: key))
    }

    /// 额度那边是 key 被拒、频率限制、没有 key 或网络不通时不再请求模型列表和 /me
    static func shouldFetchModels(after usage: UsageFetchResult) -> Bool {
        switch usage {
        case .success, .httpStatus, .unrecognizedFormat: return true
        case .denied, .unauthorized, .rateLimited, .networkFailure: return false
        }
    }

    func fetchModels(key: String) -> KimiModelsFetchResult {
        guard let response = try? environment.transport.send(request(KimiEndpoints.modelsEndpoint, key: key)),
              response.status == 200,
              let models = KimiModelsResponse.models(json: response.body) else { return .failure }
        return .success(models)
    }
}
