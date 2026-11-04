// chatgpt-profiles ticket 06：App 删除 ChatGPT 档案（App 核心 ChatGPTProfileCommands、LaunchdEnvironment）。
// App 自己不删档案：删除入口在默认档案、当前档案、launchd 里 CODEX_HOME 仍指向的档案上不可用（规则与
// ccp chatgpt rm 相同，并用真实的 ccp 交叉验证），点击后打开终端执行 `ccp chatgpt rm <名字>`。
// launchd 环境、codex、ps 一律是假的（TempHome 的 root/bin 包装与 tests/fakes/）。
// 期望值来源：ticket 06 的验收项、spec "共享资源 / 删除档案"。

import Foundation

final class ChatGPTProfileRemovalChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("ChatGPT 删除入口：默认档案、当前档案、launchd 仍指向的档案不可用", removalBlockers),
            Check("ChatGPT 删除入口的判断与真实的 ccp chatgpt rm 一致（被拒绝时不登出）", blockersAgreeWithCcp),
            Check("读取 launchd 里的 CODEX_HOME：只调用 launchctl getenv，未设置或失败时为 nil", readsLaunchdCodexHome),
            Check("ChatGPT 删除命令文字：ccp chatgpt rm <名字>", removeCommandText),
            Check("ChatGPT 删除命令：在终端里确认后登出并删除，档案从列表消失、删除完成", removeCommandDeletesProfile),
            Check("ChatGPT 删除命令：登出失败时档案留在列表里，删除不算完成", removeCommandKeepsProfileWhenLogoutFails),
        ]
    }

    static func commands(_ home: TempHome) -> ChatGPTProfileCommands {
        ChatGPTProfileCommands(environment: home.environment, bundledCcp: ProfileCommandChecks.bundledCcp)
    }

    static func removalBlockers() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        try home.makeCodexProfile("work")
        try home.makeCodexProfile("personal")
        let c = commands(home)
        let work = home.codexProfilesRoot.appendingPathComponent("work").path
        let personal = home.codexProfilesRoot.appendingPathComponent("personal").path

        try expectEqual(c.removalBlocker(profile: "default", currentProfile: "work", launchdCodexHome: nil),
                        .defaultProfile)
        try expectEqual(c.removalBlocker(profile: "work", currentProfile: "work", launchdCodexHome: work),
                        .currentProfile)
        // 当前档案记录只与目录名差在大小写：在不分大小写的文件系统上是同一个目录
        try expectEqual(c.removalBlocker(profile: "work", currentProfile: "Work", launchdCodexHome: nil),
                        .currentProfile)
        try expectEqual(c.removalBlocker(profile: "work", currentProfile: "default", launchdCodexHome: work),
                        .launchdProfile)
        try expectEqual(c.removalBlocker(profile: "work", currentProfile: "default", launchdCodexHome: work + "/"),
                        .launchdProfile, "结尾多一个 / 也是同一个目录")
        try expectEqual(c.removalBlocker(profile: "work", currentProfile: "personal", launchdCodexHome: personal),
                        nil)
        try expectEqual(c.removalBlocker(profile: "work", currentProfile: "default", launchdCodexHome: nil), nil)
        try expectEqual(c.removalBlocker(profile: "work", currentProfile: "default", launchdCodexHome: ""), nil)
        try expectEqual(c.removalBlocker(profile: "work", currentProfile: "missing", launchdCodexHome: nil), nil)
        // Claude 侧同名档案的当前档案记录与 ChatGPT 无关
        try home.makeProfileDir("personal")
        try home.write(".claude-profiles/active", "work\n")
        try expectEqual(c.removalBlocker(profile: "work", currentProfile: "personal", launchdCodexHome: nil), nil)
    }

    static func blockersAgreeWithCcp() throws {
        let ccp = ProfileCommandChecks.bundledCcp.path
        let cases: [(profile: String, active: String, launchd: String?)] = [
            ("default", "default", nil),
            ("work", "work", nil),
            ("work", "Work", nil),
            ("work", "default", "work"),
            ("work", "default", "work/"),
            ("work", "personal", "personal"),
            ("work", "default", nil),
        ]
        for (profile, active, launchd) in cases {
            let home = try TempHome()
            defer { home.remove() }
            try home.makeCodexDefault()
            try home.makeCodexProfile("work", auth: chatgptAuth(email: "w@example.com"))
            try home.makeCodexProfile("personal")
            try home.write(".codex-profiles/active", active + "\n")
            let launchdValue = launchd.map { home.codexProfilesRoot.path + "/" + $0 }
            if let launchdValue { try home.setLaunchdEnv("CODEX_HOME", launchdValue) }

            let appSays = commands(home).removalBlocker(profile: profile, currentProfile: active,
                                                        launchdCodexHome: launchdValue)
            let result = try ShellRun.run(home, [ccp, "chatgpt", "rm", profile], stdin: "y\n")
            let label = "删除 \(profile)（当前 \(active)，launchd \(launchd ?? "未设置")）"
            if let appSays {
                try expect(result.status != 0, "\(label)：App 拒绝（\(appSays)），ccp chatgpt rm 却成功了")
                try expectEqual(home.codexCalls().count, 0, "\(label)：被拒绝时不应执行 codex logout")
            } else {
                try expectEqual(result.status, 0, "\(label)：App 认为可以删除，ccp chatgpt rm 却失败了：\(result.err)")
                try expectEqual(home.codexCalls(), [["logout"]], "\(label)：应执行 codex logout")
            }
        }
    }

    static func readsLaunchdCodexHome() throws {
        let home = try TempHome()
        defer { home.remove() }
        let launchd = LaunchdEnvironment(environment: home.environment)
        let path = home.codexProfilesRoot.appendingPathComponent("work").path

        try expectEqual(launchd.codexHome(), nil, "未设置")
        try home.setLaunchdEnv("CODEX_HOME", path)
        try expectEqual(launchd.codexHome(), path)
        try home.setLaunchdEnv("CODEX_HOME", "/tmp/with space/x")
        try expectEqual(launchd.codexHome(), "/tmp/with space/x", "值里有空格时原样返回")
        try Data("3".utf8).write(to: home.fakeLaunchctlDir.appendingPathComponent("exit"))
        try expectEqual(launchd.codexHome(), nil, "launchctl 失败")

        let calls = home.launchctlCalls()
        try expectEqual(calls.count, 4)
        try expect(calls.allSatisfy { $0 == ["getenv", "CODEX_HOME"] }, "只读，不改 launchd 环境：\(calls)")
    }

    static func removeCommandText() throws {
        let home = try TempHome()
        defer { home.remove() }
        let bundled = URL(fileURLWithPath: "/Applications/CC Pilot.app/Contents/Resources/shell/bin/ccp")
        let c = ChatGPTProfileCommands(environment: home.environment, bundledCcp: bundled)
        try expectEqual(c.removeCommand("a.b_c-d"),
                        "'/Applications/CC Pilot.app/Contents/Resources/shell/bin/ccp' chatgpt rm a.b_c-d")
        try FileManager.default.copyItem(at: repoRoot.appendingPathComponent("shell"),
                                         to: home.url.appendingPathComponent(".cc-pilot"))
        try expectEqual(c.removeCommand("work"), "~/.cc-pilot/bin/ccp chatgpt rm work")
    }

    static func removeCommandDeletesProfile() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        try home.makeCodexProfile("work", auth: chatgptAuth(email: "w@example.com"))
        let store = ChatGPTProfileStore(environment: home.environment)
        let removing = ProfileCommands.PendingChange.removing("work")
        try expectEqual(removing.isFinished(inChatGPT: store.listProfiles(now: fixedNow)), false, "档案还在")

        let line = commands(home).removeCommand("work")
        let result = try ProfileCommandChecks.typeInTerminal(home, line, extraEnvironment: [:], stdin: "y\n")

        try expectEqual(result.status, 0, "执行 \(line) 的退出码（stderr：\(result.err)）")
        try expectEqual(store.listProfiles(now: fixedNow).map(\.name), ["default"])
        try expectEqual(removing.isFinished(inChatGPT: store.listProfiles(now: fixedNow)), true, "档案消失后")
    }

    static func removeCommandKeepsProfileWhenLogoutFails() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        try home.makeCodexProfile("work", auth: chatgptAuth(email: "w@example.com"))
        let line = commands(home).removeCommand("work")

        let result = try ProfileCommandChecks.typeInTerminal(home, line, extraEnvironment: ["FAKE_CODEX_EXIT": "1"],
                                                             stdin: "y\n")

        try expect(result.status != 0 && result.err.contains("auth.json"),
                   "登出失败时 ccp chatgpt rm 应以凭据仍在为由拒绝（stderr：\(result.err)）")
        let store = ChatGPTProfileStore(environment: home.environment)
        try expectEqual(store.listProfiles(now: fixedNow).map(\.name), ["default", "work"])
        try expectEqual(ProfileCommands.PendingChange.removing("work")
                            .isFinished(inChatGPT: store.listProfiles(now: fixedNow)), false)
    }
}
