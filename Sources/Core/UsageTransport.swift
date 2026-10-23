// 额度请求的网络层。App 核心只通过 CoreEnvironment.transport 联网，测试换成假的（只替换网络层）。
//
// 真实实现（URLSessionUsageTransport）：
// - 用 ephemeral 会话：不写磁盘缓存、不存 Cookie、不存认证信息，凭据不会落盘。
// - 不跟随重定向：请求头里有令牌，App 只访问额度接口这一个地址（spec "联网与发布"）。
// - 同步调用（在后台队列上用），超时由请求自己的 timeoutInterval 决定。

import Foundation

/// 一次 HTTP 响应。headers 的键一律小写。
struct UsageHTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.body = body
    }
}

/// 在后台队列上使用（UsageModel 把 UsageRefresher 交给后台队列），所以必须 Sendable
protocol UsageTransport: Sendable {
    /// 发出请求并等待响应（阻塞当前线程）。网络失败、超时时抛错。
    func send(_ request: URLRequest) throws -> UsageHTTPResponse
}

final class URLSessionUsageTransport: UsageTransport {
    static let shared = URLSessionUsageTransport()

    /// 初始化后不再改变（URLSession 本身线程安全），所以这个类可以在线程之间共享
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) throws -> UsageHTTPResponse {
        let done = DispatchSemaphore(value: 0)
        var result: Result<UsageHTTPResponse, Error> = .failure(URLError(.unknown))
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let key = key as? String, let value = value as? String { headers[key] = value }
                }
                result = .success(UsageHTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            done.signal()
        }
        task.resume()
        done.wait()
        return try result.get()
    }

    /// 不跟随重定向：把 3xx 原样交给调用方
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
