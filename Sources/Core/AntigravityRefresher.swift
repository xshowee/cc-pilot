// 刷新 Antigravity 额度（spec "数据来源""解析规则""刷新"）。Antigravity 只显示额度，同 Kimi Code 不属于 Tool，没有档案。
//
// 用法（只在用户点某张 Antigravity 卡片的刷新或"刷新全部"时调用；在后台队列上调用，会阻塞）：
//   AntigravityRefresher(environment: env).refresh(now: Date()) → AntigravityRefreshResult（交给 AntigravityBoard，ticket 02）
//
// 一次刷新 = 找进程 → 找端口 → GetUserStatus → RetrieveUserQuotaSummary：
//   1. environment.antigravityProcesses 列出 Antigravity.app 里的 language server。一个都没有 → appNotRunning，
//      不读参数、不发请求。
//   2. 逐个进程（多窗口时可能有多个）读 csrf token、列监听端口（优先读取 ~/.gemini/antigravity/daemon/hub_*.json
//      里的 csrfToken 与明文 httpPort，未命中时回退到旧版启动参数 --csrf_token 与监听套接字扫描），
//      对 http://127.0.0.1:<端口> 逐个发 GetUserStatus，
//      取第一个返回 200 的进程和端口；本次刷新后续请求用同一个端口。探测用短超时（实测 HTTPS 端口收到明文 HTTP
//      立即返回 400，但别的端口不能拖住刷新）。只走明文 HTTP：不走 HTTPS 端口，也就不涉及自签名证书。
//      一个都不行 → failed(nil, noReachablePort)；所有进程都读不出 token → failed(nil, processUnreadable)。
//   3. GetUserStatus 只读 userStatus.email、userStatus.userTier.name / id。没有 email → notSignedIn。
//   4. RetrieveUserQuotaSummary（体 {"forceRefresh": true}，绕过 language server 约 3 分钟的缓存；App 会因此以它自己的
//      身份向 Google 查询一次，所以用正常超时）。非 200、网络失败 → failed(email, …)；格式不对 → unrecognizedFormat(email)。
//
// 两个 RPC 都是 Connect 协议的 JSON POST：路径 /exa.language_server_pb.LanguageServerService/<方法>，
// 头只有 X-Codeium-Csrf-Token 与 Content-Type: application/json。请求走 environment.transport（与联网请求同一注入点）。
// 接口没有文档，格式是 2026-11-14 实测（Antigravity 2.32.1），见 tests/fixtures/antigravity/。
// csrf token 只在内存里：不出现在结果、失败原因里，也不写日志。
//
// 解析规则见 AntigravityQuotaResponse。

import Foundation

struct AntigravityRefresher: Sendable {
    static let servicePath = "/exa.language_server_pb.LanguageServerService/"
    /// 本地接口只在本机
    static let host = "127.0.0.1"
    /// 探测端口（GetUserStatus）的超时：本机接口，正常应立即返回
    static let probeTimeout: TimeInterval = 2
    /// RetrieveUserQuotaSummary 的超时：App 收到后要向 Google 查询（同 Claude 一侧）
    static let quotaTimeout: TimeInterval = UsageRefresher.timeout

    let environment: CoreEnvironment

    init(environment: CoreEnvironment = .live) {
        self.environment = environment
    }

    /// 读一次 App 当前登录账号的额度（在后台队列上调用，会阻塞）
    func refresh(now: Date = Date()) -> AntigravityRefreshResult {
        let processes = environment.antigravityProcesses
        let servers = processes.languageServers()
        guard !servers.isEmpty else { return .appNotRunning }

        var readAnyToken = false
        for server in servers {
            guard let token = processes.csrfToken(of: server) else { continue }
            readAnyToken = true
            for port in processes.listeningPorts(of: server) {
                let request = request("GetUserStatus", port: port, token: token, body: [:], timeout: Self.probeTimeout)
                guard let response = try? environment.transport.send(request), response.status == 200 else { continue }
                return fetchQuota(status: response.body, port: port, token: token, now: now)
            }
        }
        return .failed(email: nil, reason: readAnyToken ? .noReachablePort : .processUnreadable)
    }

    private func fetchQuota(status body: Data, port: Int, token: String, now: Date) -> AntigravityRefreshResult {
        let status: AntigravityQuotaResponse.UserStatus
        switch AntigravityQuotaResponse.userStatus(json: body) {
        case .unrecognized: return .unrecognizedFormat(email: nil)
        case .notSignedIn: return .notSignedIn
        case .signedIn(let signedIn): status = signedIn
        }
        let request = request("RetrieveUserQuotaSummary", port: port, token: token,
                              body: ["forceRefresh": true], timeout: Self.quotaTimeout)
        guard let response = try? environment.transport.send(request) else {
            return .failed(email: status.email, reason: .networkFailure)
        }
        guard response.status == 200 else { return .failed(email: status.email, reason: .httpStatus(response.status)) }
        guard let groups = AntigravityQuotaResponse.groups(json: response.body, now: now) else {
            return .unrecognizedFormat(email: status.email)
        }
        return .success(AntigravityAccountQuota(email: status.email, tierName: status.tierName, tierId: status.tierId,
                                                groups: groups, fetchedAt: now))
    }

    private func request(_ method: String, port: Int, token: String, body: [String: Any],
                         timeout: TimeInterval) -> URLRequest {
        Self.makeRequest(method, port: port, token: token,
                         bodyData: try? JSONSerialization.data(withJSONObject: body),
                         timeout: timeout)!
    }

    static func makeRequest(_ method: String, port: Int, token: String, bodyData: Data?,
                            timeout: TimeInterval) -> URLRequest? {
        guard let url = URL(string: "http://\(host):\(port)" + servicePath + method) else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        return request
    }
}

/// 两个 RPC 的响应（spec "解析规则"）
enum AntigravityQuotaResponse {
    struct UserStatus: Equatable {
        let email: String
        let tierName: String?
        let tierId: String?
    }

    /// GetUserStatus 读出的三种情况
    enum UserStatusReading: Equatable {
        /// 格式无法识别：不是 JSON 对象，或没有 userStatus
        case unrecognized
        /// 没有 email：App 里没有登录
        case notSignedIn
        case signedIn(UserStatus)
    }

    static func userStatus(json data: Data) -> UserStatusReading {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = root["userStatus"] as? [String: Any] else { return .unrecognized }
        guard let email = status["email"] as? String, !email.isEmpty else { return .notSignedIn }
        let tier = status["userTier"] as? [String: Any]
        return .signedIn(UserStatus(email: email, tierName: nonEmpty(tier?["name"]), tierId: nonEmpty(tier?["id"])))
    }

    /// RetrieveUserQuotaSummary 的 response.groups，按接口顺序；格式无法识别时为 nil：
    /// 没有 groups（或为空）、某组没有 displayName 或 buckets、某个桶的 window 不是 5h / weekly
    static func groups(json data: Data, now: Date) -> [AntigravityQuotaGroup]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let response = root["response"] as? [String: Any],
              let groups = response["groups"] as? [Any], !groups.isEmpty else { return nil }
        var parsed: [AntigravityQuotaGroup] = []
        for value in groups {
            guard let group = value as? [String: Any], let name = group["displayName"] as? String,
                  let buckets = group["buckets"] as? [Any] else { return nil }
            var parsedBuckets: [AntigravityQuotaBucket] = []
            for value in buckets {
                guard let bucket = value as? [String: Any], let parsedBucket = self.bucket(bucket, now: now) else {
                    return nil
                }
                parsedBuckets.append(parsedBucket)
            }
            parsed.append(AntigravityQuotaGroup(kind: kind(name), displayName: name,
                                                models: models(group["description"]), buckets: parsedBuckets))
        }
        return parsed
    }

    /// 一个桶；window 不是 5h / weekly 时为 nil（格式无法识别）
    private static func bucket(_ bucket: [String: Any], now: Date) -> AntigravityQuotaBucket? {
        guard let window = (bucket["window"] as? String).flatMap(AntigravityQuotaBucket.Window.init(rawValue:)) else {
            return nil
        }
        return AntigravityQuotaBucket(bucketId: nonEmpty(bucket["bucketId"]), displayName: nonEmpty(bucket["displayName"]),
                                      window: window, usage: usage(bucket, now: now))
    }

    /// 剩余 = remainingFraction × 100 向下取整（同 UsageWindow：宁可少报），夹到 0–100。
    /// disabled: true 的桶当 0%。remainingFraction 缺失（proto3 省略零值）而 resetTime 是未来时间：0%；
    /// 两者都缺、或重置时间已过（不知道现在剩多少）：没有数字
    private static func usage(_ bucket: [String: Any], now: Date) -> UsageWindow? {
        let resetsAt = UsageSnapshot.date(bucket["resetTime"])
        let fraction: Double
        if bucket["disabled"] as? Bool == true {
            fraction = 0
        } else if let given = UsageSnapshot.number(bucket["remainingFraction"]) {
            fraction = given
        } else if let resetsAt, resetsAt > now {
            fraction = 0
        } else {
            return nil
        }
        // 加一点余量再取整：0.29 × 100 在浮点里是 28.999…，不能显示成 28
        let remaining = (min(1, max(0, fraction)) * 100 + 1e-9).rounded(.down)
        return UsageWindow(utilization: 100 - remaining, resetsAt: resetsAt)
    }

    private static func kind(_ displayName: String) -> AntigravityQuotaGroup.Kind {
        switch displayName.lowercased() {
        case "gemini models": return .gemini
        case "claude and gpt models": return .thirdParty
        default: return .other
        }
    }

    static let modelsPrefix = "Models within this group:"

    private static func models(_ value: Any?) -> [String] {
        guard let description = value as? String, !description.isEmpty else { return [] }
        guard description.hasPrefix(modelsPrefix) else { return [description] }
        return description.dropFirst(modelsPrefix.count).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
