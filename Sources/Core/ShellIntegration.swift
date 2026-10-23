// App 安装 ccp 并接入 zsh（ticket 08）。
//
// App 内置一份 shell/（构建时复制到 Contents/Resources/shell/），与安装目录 ~/.cc-pilot/ 一一对应：
// 安装就是把它原样复制过去（见 shell/README.md）。接入与移除不自己改 ~/.zshrc，而是执行
// ~/.cc-pilot/bin/ccp init --yes / ccp uninstall，所以结果与在终端里执行完全一样。

import Foundation

struct ShellIntegration {
    /// App 启动时要做的事
    enum LaunchOutcome: Equatable {
        /// 什么都不用问
        case nothing
        /// 首次运行：要向用户说明并询问是否接入 zsh
        case askToConnect
    }

    private let environment: CoreEnvironment
    private let bundledShell: URL

    /// bundledShell：App 内置的 shell/ 目录
    init(environment: CoreEnvironment = .live, bundledShell: URL) {
        self.environment = environment
        self.bundledShell = bundledShell
    }

    /// App 启动时调用。alreadyAsked：之前是否已经问过用户（无论同意还是拒绝）。
    ///
    /// - 已经安装过（或 ~/.zshrc 里已有接入行）：把 ~/.cc-pilot/ 更新为本 App 内置的版本（App 更新后
    ///   ccp 随之更新），不询问，也不改 ~/.zshrc（用户在终端里 ccp uninstall 过就保持未接入）。
    /// - 没有接入、也没问过：返回 .askToConnect；询问之前不修改任何文件。
    /// - 拒绝过：什么都不做（之后可以从设置里调用 connect() 重新接入）。
    func prepareAtLaunch(alreadyAsked: Bool) throws -> LaunchOutcome {
        let connected = isConnected
        if isInstalled || connected {
            try updateInstalledCopy()
        }
        return alreadyAsked || connected ? .nothing : .askToConnect
    }

    /// ccp init 写入 ~/.zshrc 的接入行（与 shell/lib/zshrc.zsh 的 _ccp_zshrc_line 逐字节相同）
    static let zshrcLine = #"source "$HOME/.cc-pilot/cc-pilot.zsh"  # cc-pilot"#

    /// ~/.zshrc（是软链接时读它指向的文件）里是否有与接入行完全相同的一整行，规则与 ccp init 相同：
    /// 注释掉的、前后多了空白的、改过的行都不算。按字节比较，文件里有非 UTF-8 字节也不影响。
    var isConnected: Bool {
        let zshrc = environment.home.appendingPathComponent(".zshrc")
        guard let data = try? Data(contentsOf: zshrc) else { return false }
        let line = Data(Self.zshrcLine.utf8)
        return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .contains { Data($0) == line }
    }

    /// 用户同意接入：安装（或更新）~/.cc-pilot/，再执行 ccp init --yes
    /// 已经接入时什么都不改（ccp init 保证只有一行）。
    func connect() throws {
        try updateInstalledCopy()
        try runCcp(installedCcp, ["init", "--yes"])
    }

    /// 移除接入：执行 ccp uninstall，只删除 ~/.zshrc 里的接入行，保留 ~/.cc-pilot/（与终端里执行相同）。
    /// 还没安装时用 App 内置的 ccp 执行，不为此安装任何文件。
    func disconnect() throws {
        let ccp = FileManager.default.isExecutableFile(atPath: installedCcp.path)
            ? installedCcp : bundledShell.appendingPathComponent("bin/ccp")
        try runCcp(ccp, ["uninstall"])
    }

    // MARK: 安装

    /// 安装目录 ~/.cc-pilot/
    var installDirectory: URL {
        environment.home.appendingPathComponent(".cc-pilot", isDirectory: true)
    }

    private var installedCcp: URL { installDirectory.appendingPathComponent("bin/ccp") }

    /// ~/.cc-pilot 是否存在（是软链接也算）
    var isInstalled: Bool {
        (try? FileManager.default.attributesOfItem(atPath: installDirectory.path)) != nil
    }

    /// 已安装的内容与内置的不同时重新安装。~/.cc-pilot 是软链接时（开发者指向自己的仓库）不动它。
    private func updateInstalledCopy() throws {
        let fm = FileManager.default
        let type = (try? fm.attributesOfItem(atPath: installDirectory.path))?[.type] as? FileAttributeType
        if type == .typeSymbolicLink { return }
        if type == .typeDirectory, Self.sameTree(installDirectory, bundledShell) { return }
        try install()
    }

    /// 两个目录的内容是否相同：同样的相对路径、同样的类型、文件字节相同、可执行权限相同
    private static func sameTree(_ a: URL, _ b: URL) -> Bool {
        guard let left = snapshot(a), let right = snapshot(b) else { return false }
        return left == right
    }

    private struct Entry: Equatable {
        let type: FileAttributeType?
        let executable: Bool
        let content: Data?
    }

    private static func snapshot(_ dir: URL) -> [String: Entry]? {
        let fm = FileManager.default
        guard let paths = fm.enumerator(atPath: dir.path)?.allObjects as? [String] else { return nil }
        var result: [String: Entry] = [:]
        for rel in paths {
            let url = dir.appendingPathComponent(rel)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            let type = attrs[.type] as? FileAttributeType
            var content: Data?
            if type == .typeRegular {
                guard let data = try? Data(contentsOf: url) else { return nil }
                content = data
            } else if type == .typeSymbolicLink {
                guard let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { return nil }
                content = Data(target.utf8)
            }
            let mode = attrs[.posixPermissions] as? Int ?? 0
            result[rel] = Entry(type: type, executable: mode & 0o111 != 0, content: content)
        }
        return result
    }

    /// 把内置的 shell/ 原样复制为 ~/.cc-pilot/：先在主目录里复制一份临时目录，再整体替换，
    /// 不会留下一半新一半旧的安装目录。
    private func install() throws {
        let fm = FileManager.default
        let staging = environment.home.appendingPathComponent(".cc-pilot.installing-\(UUID().uuidString)")
        try fm.copyItem(at: bundledShell, to: staging)
        do {
            if fm.fileExists(atPath: installDirectory.path) {
                _ = try fm.replaceItemAt(installDirectory, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: installDirectory)
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    // MARK: 执行 ccp

    /// 运行 ccp 失败
    struct CcpFailure: Error, CustomStringConvertible {
        let arguments: [String]
        let status: Int32
        let message: String
        var description: String { "ccp \(arguments.joined(separator: " ")) 失败（退出码 \(status)）：\(message)" }
    }

    /// 以干净的环境运行 ccp：只有 HOME、PATH、LANG，标准输入为空（不会卡在询问上）。
    private func runCcp(_ ccp: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = ccp
        process.arguments = arguments
        process.environment = [
            "HOME": environment.home.path,
            "PATH": environment.searchPath,
            "LANG": "en_US.UTF-8",
        ]
        process.currentDirectoryURL = environment.home
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        try process.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CcpFailure(arguments: arguments, status: process.terminationStatus,
                             message: String(decoding: errData, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
