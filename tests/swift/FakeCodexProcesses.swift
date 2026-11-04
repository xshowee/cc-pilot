// 假的"运行中的 codex 进程查询"（CoreEnvironment.codexProcesses）。TempHome 默认注入一个空的：
// 检查程序绝不列出、读取用户真实的进程（不跑 lsof、不读进程环境）。
// 检查用 run(...) 摆出进程，用调用计数断言"每个进程只读一次环境、只在需要时查打开的文件"。

import Foundation

final class FakeCodexProcesses: CodexProcessQuery, @unchecked Sendable {
    private struct Entry {
        var home: CodexHomeSetting?
        var files: [String]
    }

    private let lock = NSLock()
    private var entries: [CodexProcess: Entry] = [:]
    private var order: [CodexProcess] = []
    private var _listCalls = 0
    private var _environmentReads: [CodexProcess] = []
    private var _openFileQueries: [CodexProcess] = []

    /// 摆出一个运行中的进程：环境里的 CODEX_HOME（nil = 读不出环境）和它打开的文件
    @discardableResult
    func run(pid: Int32, startedAt start: UInt64 = 1, home: CodexHomeSetting?, files: [String] = []) -> CodexProcess {
        let process = CodexProcess(pid: pid, startTime: start)
        lock.withLock {
            if entries[process] == nil { order.append(process) }
            entries[process] = Entry(home: home, files: files)
        }
        return process
    }

    /// 改一个进程打开的文件（例如它新开了一个会话）
    func open(_ files: [String], in process: CodexProcess) {
        lock.withLock { entries[process]?.files = files }
    }

    func exit(_ process: CodexProcess) {
        lock.withLock {
            entries[process] = nil
            order.removeAll { $0 == process }
        }
    }

    var listCalls: Int { lock.withLock { _listCalls } }
    var environmentReads: [CodexProcess] { lock.withLock { _environmentReads } }
    var openFileQueries: [CodexProcess] { lock.withLock { _openFileQueries } }

    // MARK: CodexProcessQuery

    func codexProcesses() -> [CodexProcess] {
        lock.withLock {
            _listCalls += 1
            return order
        }
    }

    func codexHome(of process: CodexProcess) -> CodexHomeSetting? {
        lock.withLock {
            _environmentReads.append(process)
            return entries[process]?.home
        }
    }

    func openFiles(of process: CodexProcess) -> [String] {
        lock.withLock {
            _openFileQueries.append(process)
            return entries[process]?.files ?? []
        }
    }
}
