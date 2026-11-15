// 假的"运行中的 Antigravity language server 查询"（CoreEnvironment.antigravityProcesses）。TempHome 默认注入一个空的：
// 检查程序绝不列出、读取用户真实的进程（不读进程参数、不列端口）。
// 检查用 run(...) 摆出进程（它的 csrf token 和监听端口），用调用记录断言"找不到进程时什么都不读"。

import Foundation

final class FakeAntigravityProcesses: AntigravityProcessQuery, @unchecked Sendable {
    private struct Entry {
        var token: String?
        var ports: [Int]
    }

    private let lock = NSLock()
    private var entries: [AntigravityLanguageServer: Entry] = [:]
    private var order: [AntigravityLanguageServer] = []
    private var _listCalls = 0
    private var _tokenReads: [AntigravityLanguageServer] = []
    private var _portQueries: [AntigravityLanguageServer] = []

    /// 摆出一个运行中的 language server：启动参数里的 csrf token（nil = 读不出参数）和它监听的 TCP 端口（按此顺序）
    @discardableResult
    func run(pid: Int32, startedAt start: UInt64 = 1, token: String?, ports: [Int]) -> AntigravityLanguageServer {
        let server = AntigravityLanguageServer(pid: pid, startTime: start)
        lock.withLock {
            if entries[server] == nil { order.append(server) }
            entries[server] = Entry(token: token, ports: ports)
        }
        return server
    }

    var listCalls: Int { lock.withLock { _listCalls } }
    var tokenReads: [AntigravityLanguageServer] { lock.withLock { _tokenReads } }
    var portQueries: [AntigravityLanguageServer] { lock.withLock { _portQueries } }

    // MARK: AntigravityProcessQuery

    func languageServers() -> [AntigravityLanguageServer] {
        lock.withLock {
            _listCalls += 1
            return order
        }
    }

    func csrfToken(of server: AntigravityLanguageServer) -> String? {
        lock.withLock {
            _tokenReads.append(server)
            return entries[server]?.token
        }
    }

    func listeningPorts(of server: AntigravityLanguageServer) -> [Int] {
        lock.withLock {
            _portQueries.append(server)
            return entries[server]?.ports ?? []
        }
    }
}
