// 找 Antigravity 桌面 App 运行中的 language server（spec "数据来源"）。经 CoreEnvironment.antigravityProcesses 注入：
// 检查换成假的，绝不查看用户真实的进程。怎么用这些查询见 AntigravityRefresher。
//
// 真实实现 LiveAntigravityProcessQuery 同 LiveCodexProcessQuery，不起 ps / lsof，直接用系统接口：
//   列进程        proc_listallpids + proc_pidpath；只认可执行文件名为 language_server、
//                 且位于 Antigravity.app 包内的进程（实测 /Applications/Antigravity.app/Contents/Resources/bin/language_server，
//                 不写死 /Applications）。多个窗口时可能有多个。
//   csrf token    sysctl KERN_PROCARGS2 里 --csrf_token 的值（"--csrf_token <值>" 与 "--csrf_token=<值>" 两种写法都认）。
//                 只读这一项，--host_bridge_token 等别的参数不读。token 只在内存里，不落盘、不写日志。
//   监听端口      PROC_PIDLISTFDS + PROC_PIDFDSOCKETINFO：TCP、状态为 LISTEN 的套接字的本地端口，按文件描述符顺序。
// 待真机验证（ticket 07）：端口的字节序（insi_lport 是网络字节序）、LISTEN 状态的判断、能否读到 App 进程的参数。

import Darwin
import Foundation

/// 一个运行中的 language server。pid 会被重用，所以带上启动时间
struct AntigravityLanguageServer: Hashable, Sendable {
    let pid: Int32
    /// 启动时间（微秒）
    let startTime: UInt64
}

protocol AntigravityProcessQuery: Sendable {
    /// 运行中的 Antigravity language server（可能有多个）
    func languageServers() -> [AntigravityLanguageServer]
    /// 启动参数里的 csrf token；进程已退出、读不出参数或没有这个参数时为 nil
    func csrfToken(of server: AntigravityLanguageServer) -> String?
    /// 进程监听的 TCP 端口，按文件描述符顺序
    func listeningPorts(of server: AntigravityLanguageServer) -> [Int]
}

/// 进程参数的解析与进程筛选（纯函数，检查直接用手写的字节验证）
enum AntigravityProcessArguments {
    static let executableName = "language_server"
    static let appBundleName = "Antigravity.app"
    /// 取 csrf token 的参数名（不含开头的 "--"）
    static let csrfTokenArgument = "csrf_token"

    /// 可执行文件路径是否是 Antigravity.app 包内的 language_server
    static func isLanguageServer(executablePath path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.last == Substring(executableName) else { return false }
        return components.dropLast().contains(Substring(appBundleName))
    }

    /// 参数里 name 的值："--name 值" 或 "--name=值"；没有、或值为空时为 nil
    static func value(of name: String, in arguments: [String]) -> String? {
        let flag = "--" + name
        for (index, argument) in arguments.enumerated() {
            if argument == flag {
                let next = index + 1
                guard next < arguments.count, !arguments[next].isEmpty, !arguments[next].hasPrefix("--") else { return nil }
                return arguments[next]
            }
            if argument.hasPrefix(flag + "=") {
                let value = String(argument.dropFirst(flag.count + 1))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    static func csrfToken(in arguments: [String]) -> String? {
        value(of: csrfTokenArgument, in: arguments)
    }

    /// KERN_PROCARGS2 的内容：argc（int32，本机字节序）、可执行文件路径、补齐的 NUL、argc 个参数（含 argv[0]）、
    /// 之后是环境变量，各以 NUL 结尾。返回 argv（含 argv[0]）；格式不对时为 nil
    static func arguments(fromProcArgs bytes: [UInt8]) -> [String]? {
        guard bytes.count > 4 else { return nil }
        let argc = bytes.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        var index = 4
        func skipString() { while index < bytes.count, bytes[index] != 0 { index += 1 } }
        func skipNULs() { while index < bytes.count, bytes[index] == 0 { index += 1 } }
        skipString()  // 可执行文件路径
        skipNULs()
        var arguments: [String] = []
        for _ in 0..<argc {
            guard index < bytes.count else { return nil }
            let start = index
            skipString()
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}

/// 真实实现（见文件头）
struct LiveAntigravityProcessQuery: AntigravityProcessQuery {
    func languageServers() -> [AntigravityLanguageServer] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, let path = Self.executablePath(pid),
                  AntigravityProcessArguments.isLanguageServer(executablePath: path),
                  let info = Self.bsdInfo(pid) else { return nil }
            return AntigravityLanguageServer(pid: pid, startTime: Self.startTime(info))
        }
    }

    func csrfToken(of server: AntigravityLanguageServer) -> String? {
        guard isSameProcess(server), let bytes = Self.procArgs(server.pid),
              let arguments = AntigravityProcessArguments.arguments(fromProcArgs: bytes) else { return nil }
        return AntigravityProcessArguments.csrfToken(in: arguments)
    }

    func listeningPorts(of server: AntigravityLanguageServer) -> [Int] {
        guard isSameProcess(server) else { return [] }
        let pid = server.pid
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }
        var ports: [Int] = []
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // insi_lport 是网络字节序（只用低 16 位）
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0, !ports.contains(port) { ports.append(port) }
        }
        return ports
    }

    private func isSameProcess(_ server: AntigravityLanguageServer) -> Bool {
        guard let info = Self.bsdInfo(server.pid) else { return false }
        return Self.startTime(info) == server.startTime
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func startTime(_ info: proc_bsdinfo) -> UInt64 {
        info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// sysctl KERN_PROCARGS2（只能读同一用户的进程；读不出时为 nil）
    private static func procArgs(_ pid: pid_t) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return Array(buffer.prefix(size))
    }
}
