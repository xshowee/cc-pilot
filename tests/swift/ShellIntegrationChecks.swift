// ticket 08：App 安装 ccp 与 zsh 接入（App 核心 ShellIntegration）。
// App 内置的 shell/ 就用仓库里的 shell/；接入与移除由真实的 ccp init --yes / ccp uninstall 完成，
// 所以这里按字节检查 ~/.zshrc，期望值是独立写出的字面量（与 tests/shell/test-ccp-init.zsh 的规则一致）。

import Foundation

final class ShellIntegrationChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("首次运行：没接入也没问过时要询问，且不修改任何文件", firstLaunchAsksWithoutTouchingFiles),
            Check("同意接入：安装 ccp 并在 ~/.zshrc 末尾加上与 ccp init 相同的一行", connectInstallsAndAppendsLine),
            Check("重复接入只有一行，终端里已经 ccp init 过也一样", connectTwiceKeepsOneLine),
            Check("是否已接入与终端里的 ccp init / ccp uninstall 一致", connectedFollowsTerminal),
            Check("已接入时启动不再询问（即使没有问过的记录）", connectedLaunchDoesNotAsk),
            Check("拒绝过：启动时不询问，也不修改任何文件", declinedLaunchTouchesNothing),
            Check("App 更新后启动：已安装的 ccp 更新为内置版本，不询问，~/.zshrc 不变", launchUpdatesInstalledCopy),
            Check("终端里 ccp uninstall 过：启动时仍更新已安装的 ccp，不询问也不重新接入", launchUpdatesAfterTerminalUninstall),
            Check("已接入但安装目录被删：启动时重新安装", launchReinstallsMissingCopy),
            Check("已是内置版本时启动不重写安装目录", launchKeepsUpToDateCopy),
            Check("~/.cc-pilot 是软链接时启动和接入都不替换它", symlinkedInstallIsLeftAlone),
            Check("移除接入：与 ccp uninstall 相同，只删除接入行", disconnectRemovesOnlyTheLine),
            Check("移除接入后启动不再询问，也不会重新接入", launchAfterDisconnectStaysDisconnected),
            Check("没有安装目录时也能移除接入", disconnectWithoutInstall),
            Check("ccp 失败时抛出错误，带上 ccp 的说明", connectFailureThrows),
        ]
    }

    static let line = #"source "$HOME/.cc-pilot/cc-pilot.zsh"  # cc-pilot"#

    static var bundledShell: URL { repoRoot.appendingPathComponent("shell") }

    static func integration(_ home: TempHome) -> ShellIntegration {
        ShellIntegration(environment: home.environment, bundledShell: bundledShell)
    }

    /// 主目录下所有项目的相对路径（排序后），用来确认"什么都没改"
    static func listing(_ home: TempHome) -> [String] {
        let items = FileManager.default.enumerator(atPath: home.url.path)?.allObjects as? [String] ?? []
        return items.sorted()
    }

    static func firstLaunchAsksWithoutTouchingFiles() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".zshrc", "export FOO=1\n")

        let outcome = try integration(home).prepareAtLaunch(alreadyAsked: false)

        try expectEqual(outcome, .askToConnect)
        try expectEqual(listing(home), [".zshrc"], "询问之前不应创建任何文件")
        try expectEqual(try zshrc(home), "export FOO=1\n")
    }

    static func zshrc(_ home: TempHome) throws -> String {
        try String(contentsOf: home.url.appendingPathComponent(".zshrc"), encoding: .utf8)
    }

    /// 目录里每一项"相对路径: 类型 可执行 大小 内容摘要"，按路径排序（不跟随软链接）
    static func tree(_ dir: URL) throws -> [String] {
        let fm = FileManager.default
        var result: [String] = []
        for case let rel as String in fm.enumerator(atPath: dir.path)?.allObjects ?? [] {
            let path = dir.appendingPathComponent(rel).path
            let attrs = try fm.attributesOfItem(atPath: path)
            let type = attrs[.type] as? FileAttributeType
            let mode = (attrs[.posixPermissions] as? Int ?? 0) & 0o111 != 0 ? "x" : "-"
            if type == .typeDirectory {
                result.append("\(rel): dir")
            } else {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                result.append("\(rel): \(type?.rawValue ?? "?") \(mode) \(data.count) \(data.hashValue)")
            }
        }
        return result.sorted()
    }

    static func installDir(_ home: TempHome) -> URL { home.url.appendingPathComponent(".cc-pilot") }

    static func connectInstallsAndAppendsLine() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".zshrc", "export FOO=1")   // 不以换行结尾

        try integration(home).connect()

        try expectEqual(try zshrc(home), "export FOO=1\n\(line)\n")
        try expectEqual(try tree(installDir(home)), try tree(bundledShell), "安装目录应与内置的 shell/ 完全相同")
        // 新开的 zsh 读 ~/.zshrc 后就能直接用 ccp
        let result = try ShellRun.zsh(home, "source ~/.zshrc && ccp current")
        try expectEqual(result.status, 0, "ccp current 的退出码（stderr：\(result.err)）")
        try expectEqual(result.out, "default\n")
    }

    static func terminalCcp(_ home: TempHome, _ args: String...) throws {
        let ccp = bundledShell.appendingPathComponent("bin/ccp").path
        let result = try ShellRun.run(home, [ccp] + args)
        try expectEqual(result.status, 0, "终端里 ccp \(args.joined(separator: " ")) 的退出码（stderr：\(result.err)）")
    }

    static func connectTwiceKeepsOneLine() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".zshrc", "export FOO=1\n")

        try integration(home).connect()
        try integration(home).connect()
        try expectEqual(try zshrc(home), "export FOO=1\n\(line)\n")

        let other = try TempHome()
        defer { other.remove() }
        try other.write(".zshrc", "export FOO=1\n")
        try FileManager.default.copyItem(at: bundledShell, to: installDir(other))
        try terminalCcp(other, "init", "--yes")
        try integration(other).connect()
        try expectEqual(try zshrc(other), "export FOO=1\n\(line)\n")
    }

    static func connectedFollowsTerminal() throws {
        let home = try TempHome()
        defer { home.remove() }
        let shell = integration(home)
        try expectEqual(shell.isConnected, false, "没有 ~/.zshrc")
        try home.write(".zshrc", "# \(line)\n \(line)\n")
        try expectEqual(shell.isConnected, false, "注释掉的或多了空白的行不算")

        try FileManager.default.copyItem(at: bundledShell, to: installDir(home))
        try terminalCcp(home, "init", "--yes")
        try expectEqual(shell.isConnected, true, "ccp init 之后")
        try terminalCcp(home, "uninstall")
        try expectEqual(shell.isConnected, false, "ccp uninstall 之后")
    }

    static func connectedLaunchDoesNotAsk() throws {
        let home = try TempHome()
        defer { home.remove() }
        try integration(home).connect()

        try expectEqual(try integration(home).prepareAtLaunch(alreadyAsked: false), .nothing)
    }

    static func declinedLaunchTouchesNothing() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".zshrc", "export FOO=1\n")

        try expectEqual(try integration(home).prepareAtLaunch(alreadyAsked: true), .nothing)
        try expectEqual(listing(home), [".zshrc"])
        try expectEqual(try zshrc(home), "export FOO=1\n")
    }

    /// 把安装目录改成"旧版本"：改一个文件、多一个文件、去掉 ccp 的可执行权限
    static func makeOutdated(_ home: TempHome) throws {
        let dir = installDir(home)
        try Data("# old version\n".utf8).write(to: dir.appendingPathComponent("lib/cmd-ls.zsh"))
        try Data("# removed in new version\n".utf8).write(to: dir.appendingPathComponent("lib/cmd-old.zsh"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: dir.appendingPathComponent("bin/ccp").path)
        try expect(try tree(dir) != tree(bundledShell), "准备旧版本失败")
    }

    static func launchUpdatesInstalledCopy() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".zshrc", "export FOO=1\n")
        try integration(home).connect()
        try makeOutdated(home)

        for asked in [true, false] {
            try expectEqual(try integration(home).prepareAtLaunch(alreadyAsked: asked), .nothing)
        }
        try expectEqual(try tree(installDir(home)), try tree(bundledShell))
        try expectEqual(try zshrc(home), "export FOO=1\n\(line)\n")
        try expectEqual(listing(home).filter { !$0.hasPrefix(".cc-pilot/") }, [".cc-pilot", ".zshrc"],
                        "不应留下临时目录或备份")
    }

    static func launchUpdatesAfterTerminalUninstall() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".zshrc", "export FOO=1\n")
        try integration(home).connect()
        try terminalCcp(home, "uninstall")
        try makeOutdated(home)

        try expectEqual(try integration(home).prepareAtLaunch(alreadyAsked: true), .nothing)
        try expectEqual(try tree(installDir(home)), try tree(bundledShell))
        try expectEqual(try zshrc(home), "export FOO=1\n")
    }

    static func launchReinstallsMissingCopy() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".zshrc", "\(line)\n")

        try expectEqual(try integration(home).prepareAtLaunch(alreadyAsked: true), .nothing)
        try expectEqual(try tree(installDir(home)), try tree(bundledShell))
        try expectEqual(try zshrc(home), "\(line)\n")
    }

    static func inode(_ url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int ?? -1
    }

    static func launchKeepsUpToDateCopy() throws {
        let home = try TempHome()
        defer { home.remove() }
        try integration(home).connect()
        let before = try inode(installDir(home))

        _ = try integration(home).prepareAtLaunch(alreadyAsked: true)
        try expectEqual(try inode(installDir(home)), before, "安装目录不应被替换")
        try expectEqual(listing(home).filter { !$0.hasPrefix(".cc-pilot/") }, [".cc-pilot", ".zshrc"],
                        "不应留下临时目录")
    }

    static func symlinkedInstallIsLeftAlone() throws {
        let home = try TempHome()
        defer { home.remove() }
        let dev = home.root.appendingPathComponent("dev shell")
        try FileManager.default.copyItem(at: bundledShell, to: dev)
        try Data("# developer's edit\n".utf8).write(to: dev.appendingPathComponent("lib/cmd-ls.zsh"))
        try FileManager.default.createSymbolicLink(at: installDir(home), withDestinationURL: dev)
        let devTree = try tree(dev)

        _ = try integration(home).prepareAtLaunch(alreadyAsked: true)
        try integration(home).connect()

        try expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: installDir(home).path), dev.path)
        try expectEqual(try tree(dev), devTree)
        try expectEqual(try zshrc(home), "\(line)\n")
    }

    static func disconnectRemovesOnlyTheLine() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".zshrc", "export FOO=1\n# \(line)\n")
        try integration(home).connect()
        let url = home.url.appendingPathComponent(".zshrc")
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write(Data("alias x=y\n".utf8))
        try handle.close()

        try integration(home).disconnect()

        try expectEqual(try zshrc(home), "export FOO=1\n# \(line)\nalias x=y\n")
        try expectEqual(integration(home).isConnected, false)
        try expectEqual(try tree(installDir(home)), try tree(bundledShell), "与 ccp uninstall 一样保留安装目录")
    }

    static func launchAfterDisconnectStaysDisconnected() throws {
        let home = try TempHome()
        defer { home.remove() }
        try integration(home).connect()
        try integration(home).disconnect()

        try expectEqual(try integration(home).prepareAtLaunch(alreadyAsked: true), .nothing)
        try expectEqual(try zshrc(home), "")
    }

    static func disconnectWithoutInstall() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".zshrc", "export FOO=1\n\(line)\n")

        try integration(home).disconnect()

        try expectEqual(try zshrc(home), "export FOO=1\n")
        try expectEqual(listing(home), [".zshrc"], "移除接入不应安装任何文件")
    }

    static func connectFailureThrows() throws {
        let home = try TempHome()
        defer { home.remove() }
        // ~/.zshrc 是目录：ccp init 无法读取，报错
        try FileManager.default.createDirectory(at: home.url.appendingPathComponent(".zshrc"),
                                                withIntermediateDirectories: true)
        do {
            try integration(home).connect()
            throw CheckFailure(description: "应当抛出错误")
        } catch let failure as ShellIntegration.CcpFailure {
            try expectEqual(failure.status, 1)
            try expect(failure.message.contains(".zshrc"), "错误说明应来自 ccp：\(failure.message)")
        }
    }
}
