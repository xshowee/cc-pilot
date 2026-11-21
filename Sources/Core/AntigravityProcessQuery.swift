// 找 Antigravity 桌面 App 运行中的 language server（spec "数据来源"）。经 CoreEnvironment.antigravityProcesses 注入：
// 检查换成假的，绝不查看用户真实的进程。怎么用这些查询见 AntigravityRefresher。
//
// 真实实现 LiveAntigravityProcessQuery 同 LiveCodexProcessQuery，不起 ps / lsof，直接用系统接口：
//   列进程        proc_listallpids + proc_pidpath；只认可执行文件名为 language_server、
//                 且位于 Antigravity.app 包内的进程（实测 /Applications/Antigravity.app/Contents/Resources/bin/language_server，
//                 不写死 /Applications）。多个窗口时可能有多个。
//   csrf token    Antigravity 2.34.0+ 优先按 pid 读取 ~/.gemini/antigravity/daemon/hub_*.json 里的 csrfToken；
//                 找不到时回退到 sysctl KERN_PROCARGS2 里 --csrf_token 的值（"--csrf_token <值>" 与
//                 "--csrf_token=<值>" 两种写法都认）。只读这一项，--host_bridge_token 等别的参数不读。
//                 token 只在内存里，不落盘、不写日志。
//   监听端口      优先放同一守护文件里的明文 httpPort（不读 httpsPort），其后附带 PROC_PIDLISTFDS +
//                 PROC_PIDFDSOCKETINFO 查到的 TCP LISTEN 本地端口并去重（按文件描述符顺序），兼作兜底。

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
    /// 对应 language server 的 csrf token；进程已退出、守护文件与启动参数均读不出时为 nil
    func csrfToken(of server: AntigravityLanguageServer) -> String?
    /// 进程监听的 TCP 端口（守护文件的明文 httpPort 优先，其后按文件描述符顺序附带套接字端口）
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

    /// 先从守护文件（~/.gemini/antigravity/daemon/hub_*.json）按 pid 取 csrf token，
    /// 取不到时再调用 procArgs 回调回退到旧版 KERN_PROCARGS2 命令行参数。
    static func resolveCsrfToken(
        pid: Int32,
        daemonDirectory: URL,
        procArgs: () -> [UInt8]?
    ) -> String? {
        if let token = AntigravityHubDaemon.csrfToken(forPID: pid, in: daemonDirectory) {
            return token
        }
        guard let bytes = procArgs(),
              let arguments = arguments(fromProcArgs: bytes) else { return nil }
        return csrfToken(in: arguments)
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

/// 读取 Antigravity 2.34.0+ 写入的 ~/.gemini/antigravity/daemon/hub_*.json 守护描述文件
enum AntigravityHubDaemon {
    static let daemonRelativePath = ".gemini/antigravity/daemon"
    static let filePrefix = "hub_"
    static let fileSuffix = ".json"

    struct Record: Equatable, Sendable {
        let pid: Int32
        let csrfToken: String?
        let httpPort: Int?
    }

    static func daemonDirectory(in home: URL) -> URL {
        home.appendingPathComponent(daemonRelativePath, isDirectory: true)
    }

    static func isHubFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix(filePrefix)
            && lower.hasSuffix(fileSuffix)
            && lower.count >= filePrefix.count + fileSuffix.count
    }

    /// 解析单个 hub_*.json 文件；仅读取 pid、csrfToken（或 csrf_token）与明文 httpPort（或 port），不读取 httpsPort
    static func parse(data: Data) -> Record? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawPID = exactInt(object["pid"]),
              rawPID > 0,
              let pid = Int32(exactly: rawPID) else {
            return nil
        }
        let csrfToken = nonEmptyString(object["csrfToken"]) ?? nonEmptyString(object["csrf_token"])
        let httpPort = validPort(object["httpPort"]) ?? validPort(object["port"])
        return Record(pid: pid, csrfToken: csrfToken, httpPort: httpPort)
    }

    /// 列出目录中属于指定 pid 的 hub_*.json 记录，按文件修改时间降序排列（时间相同时按文件名降序）
    static func records(forPID pid: Int32, in directory: URL) -> [Record] {
        guard pid > 0,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                  options: [.skipsSubdirectoryDescendants]
              ) else {
            return []
        }
        var matched: [(date: Date, name: String, record: Record)] = []
        for url in urls {
            let name = url.lastPathComponent
            guard isHubFileName(name) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            guard let data = try? Data(contentsOf: url),
                  let record = parse(data: data),
                  record.pid == pid else {
                continue
            }
            matched.append((values?.contentModificationDate ?? .distantPast, name, record))
        }
        matched.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.name > rhs.name
        }
        return matched.map(\.record)
    }

    static func csrfToken(forPID pid: Int32, in directory: URL) -> String? {
        records(forPID: pid, in: directory).compactMap(\.csrfToken).first
    }

    /// 守护文件里的明文 httpPort 排在前面，套接字端口附在后面作为兜底；过滤越界端口并保留首次出现顺序去重
    static func mergedPorts(forPID pid: Int32, in directory: URL, socketPorts: [Int]) -> [Int] {
        let daemonPorts = records(forPID: pid, in: directory).compactMap(\.httpPort)
        var merged: [Int] = []
        for port in daemonPorts + socketPorts where (1...65535).contains(port) && !merged.contains(port) {
            merged.append(port)
        }
        return merged
    }

    private static func validPort(_ value: Any?) -> Int? {
        guard let port = exactInt(value), (1...65535).contains(port) else { return nil }
        return port
    }

    private static func exactInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, abs(double) <= Double(1 << 52) else { return nil }
        let int64 = number.int64Value
        guard Double(int64) == double else { return nil }
        return Int(exactly: int64)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 真实实现（见文件头）
struct LiveAntigravityProcessQuery: AntigravityProcessQuery {
    let daemonDirectory: URL

    init(daemonDirectory: URL) {
        self.daemonDirectory = daemonDirectory
    }

    init(home: URL = CoreEnvironment.userHome()) {
        self.daemonDirectory = AntigravityHubDaemon.daemonDirectory(in: home)
    }

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
        guard isSameProcess(server) else { return nil }
        return AntigravityProcessArguments.resolveCsrfToken(
            pid: server.pid,
            daemonDirectory: daemonDirectory,
            procArgs: { Self.procArgs(server.pid) }
        )
    }

    func listeningPorts(of server: AntigravityLanguageServer) -> [Int] {
        guard isSameProcess(server) else { return [] }
        return AntigravityHubDaemon.mergedPorts(
            forPID: server.pid,
            in: daemonDirectory,
            socketPorts: Self.socketListeningPorts(of: server.pid)
        )
    }

    private static func socketListeningPorts(of pid: pid_t) -> [Int] {
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
