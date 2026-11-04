// "按会话找写入进程的 CODEX_HOME"的底层查询（spec "会话记录、账本与归属"，chatgpt-profiles ticket 08）。
// 经 CoreEnvironment.codexProcesses 注入：检查换成假的，绝不查看用户真实的进程。
// 怎么用这些查询（何时查、缓存什么）见 ChatGPTSessionWriters。
//
// 真实实现 LiveCodexProcessQuery 不启动 lsof，直接用 lsof 自己用的系统接口（libproc、sysctl），得到同样的信息、
// 不必每次起一个子进程：
//   列进程        proc_listallpids + PROC_PIDTBSDINFO（名字、启动时间）；只要名字以 codex 开头的
//                 （codex CLI、桌面 App 内嵌的 codex app-server、codex-acp 等；npm 装的 node 包装进程不算，
//                 真正写会话的是它启动的 codex）。
//   读环境        sysctl KERN_PROCARGS2（只能读同一用户的进程；读不出时为 nil）。
//   打开的文件    PROC_PIDLISTFDS + PROC_PIDFDVNODEPATHINFO（同 lsof -p <pid>，路径是解析过软链接的真实路径）。
// 待真机验证（ticket 13）：桌面 App 与它的守护进程的进程名、能否读到它们的环境。

import Darwin
import Foundation

/// 一个运行中的进程。pid 会被重用，所以带上启动时间
struct CodexProcess: Hashable, Sendable {
    let pid: Int32
    /// 启动时间（微秒）
    let startTime: UInt64
}

/// 进程环境里的 CODEX_HOME
enum CodexHomeSetting: Equatable, Sendable {
    /// 没有这个变量（或为空）：默认档案
    case unset
    case path(String)
}

protocol CodexProcessQuery: Sendable {
    /// 运行中的 codex 进程（便宜，可以常调用）
    func codexProcesses() -> [CodexProcess]
    /// 进程环境里的 CODEX_HOME；进程已退出或读不出环境时为 nil。进程的环境不会变，调用方每个进程只读一次
    func codexHome(of process: CodexProcess) -> CodexHomeSetting?
    /// 进程打开的文件的路径（较贵：只在需要时调用）
    func openFiles(of process: CodexProcess) -> [String]
}

/// 真实实现（见文件头）
struct LiveCodexProcessQuery: CodexProcessQuery {
    func codexProcesses() -> [CodexProcess] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, let info = Self.bsdInfo(pid) else { return nil }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name.lowercased().hasPrefix("codex") else { return nil }
            return CodexProcess(pid: pid, startTime: Self.startTime(info))
        }
    }

    func codexHome(of process: CodexProcess) -> CodexHomeSetting? {
        guard let info = Self.bsdInfo(process.pid), Self.startTime(info) == process.startTime,
              let environment = Self.environment(of: process.pid) else { return nil }
        guard let value = environment["CODEX_HOME"], !value.isEmpty else { return .unset }
        return .path(value)
    }

    func openFiles(of process: CodexProcess) -> [String] {
        let pid = process.pid
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info,
                                     Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard got == Int32(MemoryLayout<vnode_fdinfowithpath>.size) else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) {
                String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func startTime(_ info: proc_bsdinfo) -> UInt64 {
        info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// KERN_PROCARGS2：argc（int32）、可执行文件路径、补齐的 NUL、argc 个参数、之后是环境变量，各以 NUL 结尾
    private static func environment(of pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix(size)
        let argc = bytes.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var index = 4
        func skipString() { while index < bytes.count, bytes[index] != 0 { index += 1 } }
        func skipNULs() { while index < bytes.count, bytes[index] == 0 { index += 1 } }
        skipString()  // 可执行文件路径
        skipNULs()
        for _ in 0..<argc {
            skipString()
            index += 1
        }
        var environment: [String: String] = [:]
        while index < bytes.count, bytes[index] != 0 {
            let start = index
            skipString()
            let entry = String(decoding: bytes[start..<index], as: UTF8.self)
            if let equals = entry.firstIndex(of: "=") {
                environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
            }
            index += 1
        }
        return environment
    }
}
