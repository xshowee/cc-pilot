// 假的网络层：替换 App 核心的 UsageTransport，记录每一次请求，按请求里的令牌返回测试准备好的响应。
// TempHome 默认就注入一个（没有准备响应时一律当作网络不通），检查程序绝不会访问真的网络。

import Foundation

final class FakeUsageTransport: UsageTransport {
    struct Response {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: String
    }

    /// 收到的请求，按顺序
    private(set) var requests: [URLRequest] {
        get { lock.withLock { _requests } }
        set { lock.withLock { _requests = newValue } }
    }

    private var _requests: [URLRequest] = []
    private var responses: [String: Response] = [:]
    private let lock = NSLock()

    var requestCount: Int { requests.count }

    /// 带这个 accessToken 的请求返回 response
    func respond(toToken token: String, _ response: Response) {
        lock.withLock { responses[token] = response }
    }

    /// 带这个 accessToken 的请求当作网络不通
    func forget(token: String) {
        lock.withLock { responses[token] = nil }
    }

    /// 带这个 accessToken 的请求返回 200 和 body
    func respond(toToken token: String, body: String) {
        respond(toToken: token, Response(body: body))
    }

    func send(_ request: URLRequest) throws -> UsageHTTPResponse {
        let response: Response? = lock.withLock {
            _requests.append(request)
            let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            return responses[String(auth.dropFirst("Bearer ".count))]
        }
        guard let response else { throw URLError(.notConnectedToInternet) }
        return UsageHTTPResponse(status: response.status, headers: response.headers, body: Data(response.body.utf8))
    }
}

/// 额度接口的响应体。window 传 nil 表示不写这个键，传 .null 表示写 JSON null。
enum WindowJSON {
    case null
    case used(Double?, resetsAt: String?)
}

func usageJSON(fiveHour: WindowJSON? = .used(25, resetsAt: "2027-01-15T08:00:00.123456+00:00"),
               sevenDay: WindowJSON? = .used(60, resetsAt: "2027-01-20T09:30:00+00:00"),
               extra: [String: Any] = [:]) -> String {
    func encode(_ w: WindowJSON) -> Any {
        switch w {
        case .null: return NSNull()
        case .used(let u, let r):
            return ["utilization": u.map { $0 as Any } ?? NSNull(), "resets_at": r.map { $0 as Any } ?? NSNull()]
        }
    }
    var root: [String: Any] = extra
    if let fiveHour { root["five_hour"] = encode(fiveHour) }
    if let sevenDay { root["seven_day"] = encode(sevenDay) }
    let data = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}
