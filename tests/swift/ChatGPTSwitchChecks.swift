// chatgpt-profiles ticket 04：App 切换 ChatGPT 档案（App 核心 ChatGPTProfileSwitcher）。
// 切换逻辑只在 shell 里实现一份：App 在后台执行 ccp chatgpt use <名字>，
// App 启动时执行 ccp chatgpt use <当前档案>。接缝：ChatGPTProfileSwitcher 的公开方法；
// 默认用仓库里真实的 shell/bin/ccp（当作 App 内置的 ccp），launchd 与桌面 App 是 TempHome 的假程序。
// 期望值来源：ticket 04 的验收项（命令形状、launchd 的 CODEX_HOME、桌面 App 绝不被退出 / 重新打开）。

import Foundation

final class ChatGPTSwitchChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("App 拼出的命令：ccp chatgpt use <名字>", arguments),
            Check("切换：写当前档案记录、launchd 的 CODEX_HOME 指向档案目录，不退出也不重新打开桌面 App", switchLeavesAppAlone),
            Check("切回默认档案：launchd 里去掉 CODEX_HOME", switchToDefaultUnsets),
            Check("ccp 非零退出：抛出错误；stderr 有输出但退出码 0 仍算成功", failureOnlyFromExitStatus),
            Check("档案不存在：抛出错误、带上 ccp 的说明，记录与 launchd 不变", missingProfileThrows),
            Check("已安装 ~/.cc-pilot 时执行已安装的 ccp", usesInstalledCcp),
            Check("App 启动时：按当前档案执行一次 ccp chatgpt use，恢复 launchd 的 CODEX_HOME，不碰桌面 App", restoreAtLaunch),
            Check("App 启动时：当前档案是默认档案，launchd 里去掉 CODEX_HOME", restoreDefaultAtLaunch),
            Check("App 启动时：没用过 ChatGPT 档案（没有 ~/.codex-profiles）就不执行 ccp", restoreSkippedWithoutProfiles),
            Check("App 更新后启动：已安装的用户拿到 codex 包装函数，~/.zshrc 不变", updateDeliversCodexWrapper),
        ]
    }

    static var bundledCcp: URL { repoRoot.appendingPathComponent("shell/bin/ccp") }

    static func switcher(_ home: TempHome) -> ChatGPTProfileSwitcher {
        ChatGPTProfileSwitcher(environment: home.environment, bundledCcp: bundledCcp)
    }

    static func profileHome(_ home: TempHome, _ name: String) -> String {
        home.url.path + "/.codex-profiles/" + name
    }

    /// 假桌面 App 收到的退出请求次数
    static func quitRequests(_ home: TempHome) -> Int {
        home.chatgptAppCalls().filter { $0.last?.hasSuffix(" to quit") == true }.count
    }

    static func opens(_ home: TempHome) -> Int {
        home.chatgptAppCalls().filter { $0 == ["-b", "com.openai.codex"] }.count
    }

    static func arguments() throws {
        try expectEqual(ChatGPTProfileSwitcher.arguments(switchingTo: "work"), ["chatgpt", "use", "work"])
        try expectEqual(ChatGPTProfileSwitcher.arguments(switchingTo: "default"), ["chatgpt", "use", "default"])
    }

    static func switchLeavesAppAlone() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        try home.makeCodexProfile("work")
        try home.chatgptApp("running")

        try switcher(home).switchTo("work")

        try expectEqual(ChatGPTProfileStore(environment: home.environment).currentProfileName(), "work")
        try expectEqual(home.launchdEnv("CODEX_HOME"), profileHome(home, "work"))
        try expectEqual(quitRequests(home), 0, "不应请桌面 App 退出")
        try expectEqual(opens(home), 0, "不应打开桌面 App")
        try expectEqual(home.chatgptAppRunningHome, "", "桌面 App 仍在运行（还是启动时的环境）")
    }

    static func switchToDefaultUnsets() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexProfile("work")
        try home.setLaunchdEnv("CODEX_HOME", profileHome(home, "work"))

        try switcher(home).switchTo("default")
        try expectEqual(home.launchdEnv("CODEX_HOME"), nil)
        try expectEqual(ChatGPTProfileStore(environment: home.environment).currentProfileName(), "default")
    }

    static func failureOnlyFromExitStatus() throws {
        let home = try TempHome()
        defer { home.remove() }
        let ccp = home.url.appendingPathComponent(".cc-pilot/bin/ccp")
        func installCcp(_ body: String) throws {
            try home.write(".cc-pilot/bin/ccp", "#!/bin/zsh -f\n" + body + "\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ccp.path)
        }
        // stderr 上有别的输出（例如某个程序的警告），但退出码 0：仍是切换成功
        try installCcp("print -u2 -r -- 'warning: something unrelated'; exit 0")
        try switcher(home).switchTo("work")
        // 非零退出码：失败，带上 ccp 的说明
        try installCcp("print -u2 -r -- 'launchctl 失败'; exit 1")
        do {
            try switcher(home).switchTo("work")
            throw CheckFailure(description: "退出码 1 应抛出错误")
        } catch let failure as ChatGPTProfileSwitcher.Failure {
            try expectEqual(failure.status, 1)
            try expect(failure.message.contains("launchctl 失败"), "错误里应带上 ccp 的说明：\(failure.message)")
        }
    }

    static func missingProfileThrows() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexProfile("work")
        try home.write(".codex-profiles/active", "work\n")
        try home.setLaunchdEnv("CODEX_HOME", profileHome(home, "work"))

        do {
            try switcher(home).switchTo("gone")
            throw CheckFailure(description: "档案不存在时应抛出错误")
        } catch let failure as ChatGPTProfileSwitcher.Failure {
            try expect(failure.message.contains("gone"), "错误里应带上 ccp 的说明：\(failure.message)")
        }
        try expectEqual(ChatGPTProfileStore(environment: home.environment).currentProfileName(), "work")
        try expectEqual(home.launchdEnv("CODEX_HOME"), profileHome(home, "work"))
    }

    /// 在 ~/.cc-pilot/bin/ccp 放一个只记录参数的假 ccp，记录写到 root/installed-ccp-args
    static func installRecordingCcp(_ home: TempHome) throws {
        let log = home.root.appendingPathComponent("installed-ccp-args").path
        try home.write(".cc-pilot/bin/ccp", "#!/bin/zsh -f\nprint -rl -- \"$@\" > \(ProfileCommands.shellQuote(log))\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: home.url.appendingPathComponent(".cc-pilot/bin/ccp").path)
    }

    static func installedCcpArgs(_ home: TempHome) -> [String]? {
        (try? String(contentsOf: home.root.appendingPathComponent("installed-ccp-args"), encoding: .utf8))
            .map { $0.split(separator: "\n").map(String.init) }
    }

    static func usesInstalledCcp() throws {
        let home = try TempHome()
        defer { home.remove() }
        try installRecordingCcp(home)

        try switcher(home).switchTo("work")

        try expectEqual(installedCcpArgs(home), ["chatgpt", "use", "work"])
        try expectEqual(home.launchctlCalls().count, 0, "执行的是已安装的（假）ccp，不是内置的")
    }

    static func restoreAtLaunch() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexProfile("work")
        try home.write(".codex-profiles/active", "work\n")
        try home.chatgptApp("running")

        try expect(try switcher(home).restoreAtLaunch(), "有 ChatGPT 档案时应执行")

        try expectEqual(home.launchdEnv("CODEX_HOME"), profileHome(home, "work"))
        try expectEqual(quitRequests(home), 0, "启动时不应退出桌面 App")
        try expectEqual(opens(home), 0, "启动时不应打开桌面 App")
        try expectEqual(try String(contentsOf: home.codexProfilesRoot.appendingPathComponent("active"), encoding: .utf8),
                        "work\n", "记录内容不变")
    }

    static func restoreDefaultAtLaunch() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexProfile("work")
        try home.write(".codex-profiles/active", "default\n")
        try home.setLaunchdEnv("CODEX_HOME", profileHome(home, "work"))

        try expect(try switcher(home).restoreAtLaunch(), "有 ChatGPT 档案时应执行")
        try expectEqual(home.launchdEnv("CODEX_HOME"), nil)
    }

    static func restoreSkippedWithoutProfiles() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        try installRecordingCcp(home)

        try expect(!(try switcher(home).restoreAtLaunch()), "没有 ~/.codex-profiles 时不应执行")
        try expectEqual(installedCcpArgs(home), nil, "不应执行 ccp")
        try expectEqual(home.launchctlCalls().count, 0)
    }

    static func updateDeliversCodexWrapper() throws {
        let home = try TempHome()
        defer { home.remove() }
        // 旧版本的安装：入口里还没有 codex 包装函数
        try home.write(".cc-pilot/cc-pilot.zsh", "function claude { command claude \"$@\" }\n")
        let zshrc = "export FOO=1\n" + ShellIntegration.zshrcLine + "\n"
        try home.write(".zshrc", zshrc)

        _ = try ShellIntegration(environment: home.environment, bundledShell: repoRoot.appendingPathComponent("shell"))
            .prepareAtLaunch(alreadyAsked: true)

        let probe = try ShellRun.zsh(home, #"source "$HOME/.cc-pilot/cc-pilot.zsh" && whence -w codex"#)
        try expectEqual(probe.out, "codex: function\n", "更新后的入口应定义 codex 函数（stderr：\(probe.err)）")
        try expectEqual(try String(contentsOf: home.url.appendingPathComponent(".zshrc"), encoding: .utf8), zshrc)
    }
}
