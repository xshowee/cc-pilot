// ticket 09：App 添加与删除档案（App 核心 ProfileCommands）。
// App 自己不实现添加和删除，只在提交前检查档案名、决定删除入口是否可用、拼出交给终端执行的 ccp 命令。
// 档案名规则的期望值与 tests/shell/test-ccp-add.zsh 一致，并且用真实的 ccp add 交叉验证。

import Foundation

final class ProfileCommandChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("新档案名：不合规、保留名、已存在时给出对应的问题", newNameProblems),
            Check("新档案名的判断与真实的 ccp add 一致", newNameAgreesWithCcpAdd),
            Check("添加命令：在终端里执行后，新档案登录完成即显示为已登录并带邮箱", addCommandLeadsToSignedInProfile),
            Check("命令文字：装了 ~/.cc-pilot 用它，没装用 App 内置的 ccp（路径带空格时加引号）", commandText),
            Check("默认档案和当前档案的删除入口不可用，与 ccp rm 一致", removalBlockers),
            Check("删除命令：在终端里确认并登出后，档案从列表中消失", removeCommandDeletesLoggedOutProfile),
            Check("删除命令：仍在登录时 ccp rm 拒绝删除，档案留在列表里", removeCommandKeepsSignedInProfile),
        ]
    }

    static func commands(_ home: TempHome) -> ProfileCommands {
        ProfileCommands(environment: home.environment, bundledCcp: bundledCcp)
    }

    static var bundledCcp: URL { repoRoot.appendingPathComponent("shell/bin/ccp") }

    static func newNameProblems() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        try home.write(".claude-profiles/stray-file", "x")
        let c = commands(home)

        try expectEqual(c.newNameProblem(""), .empty)
        for bad in ["-x", ".hidden", "_a", "a b", "a/b", "名字", "ａ", "a\n", " a"] {
            try expectEqual(c.newNameProblem(bad), .malformed, "名字 \(bad.debugDescription)")
        }
        try expectEqual(c.newNameProblem("default"), .reserved)
        try expectEqual(c.newNameProblem("active"), .reserved)
        try expectEqual(c.newNameProblem("work"), .exists)
        try expectEqual(c.newNameProblem("stray-file"), .exists, "同名的文件也算已存在（与 ccp add 一致）")
        for good in ["personal", "Work2", "a.b_c-d", "9"] {
            try expectEqual(c.newNameProblem(good), nil, "名字 \(good)")
        }
    }

    /// 假 claude 的环境：记录目录放在临时根目录里；hook 是它记录完之后执行的 zsh 代码
    static func fakeClaude(_ home: TempHome, hook: String? = nil) -> [String: String] {
        var env = ["FAKE_CLAUDE_LOG_DIR": home.root.appendingPathComponent("claude-log").path,
                   "FAKE_SECURITY_DIR": home.fakeSecurityDir.path]
        if let hook { env["FAKE_CLAUDE_HOOK"] = hook }
        return env
    }

    /// 像用户在终端里那样执行一行命令（zsh 解析这一行）
    static func typeInTerminal(_ home: TempHome, _ line: String, extraEnvironment: [String: String],
                               stdin: String? = nil) throws -> ShellRun.Result {
        try ShellRun.run(home, ["/bin/zsh", "-f", "-c", line], extraEnvironment: extraEnvironment, stdin: stdin)
    }

    static func newNameAgreesWithCcpAdd() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        let names = ["", "-x", ".hidden", "a b", "名字", "default", "active", "work", "personal", "a.b_c-d"]
        for name in names {
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: home.profilesRoot.path))
            let appSays = commands(home).newNameProblem(name)
            let result = try ShellRun.run(home, [bundledCcp.path, "add", name], extraEnvironment: fakeClaude(home))
            let created = Set(try FileManager.default.contentsOfDirectory(atPath: home.profilesRoot.path))
                .subtracting(before)
            if let appSays {
                try expect(result.status != 0, "App 拒绝 \(name.debugDescription)（\(appSays)），ccp add 却成功了")
                try expectEqual(created, [], "ccp add 拒绝 \(name.debugDescription) 时不应创建任何东西")
            } else {
                try expectEqual(result.status, 0, "App 认为 \(name.debugDescription) 可以新建，ccp add 却失败了：\(result.err)")
                try expectEqual(created, [name])
            }
        }
    }

    static func addCommandLeadsToSignedInProfile() throws {
        let home = try TempHome()
        defer { home.remove() }
        // 假 claude 模拟用户在新档案里完成登录：Claude Code 把账号资料写进这个档案的 .claude.json
        let login = #"print -r -- '{"oauthAccount":{"accountUuid":"u-new","emailAddress":"new@example.com"}}' > $CLAUDE_CONFIG_DIR/.claude.json"#
        let line = commands(home).addCommand("work")

        let result = try typeInTerminal(home, line, extraEnvironment: fakeClaude(home, hook: login))

        try expectEqual(result.status, 0, "执行 \(line) 的退出码（stderr：\(result.err)）")
        let work = ProfileStore(environment: home.environment).listProfiles().first { $0.name == "work" }
        try expectEqual(work?.account.account?.email, "new@example.com", "列表里的 work 应已登录并带邮箱")
    }

    static func commandText() throws {
        let home = try TempHome()
        defer { home.remove() }
        let bundled = URL(fileURLWithPath: "/Applications/CC Pilot.app/Contents/Resources/shell/bin/ccp")
        let c = ProfileCommands(environment: home.environment, bundledCcp: bundled)

        try expectEqual(c.addCommand("work"), "'/Applications/CC Pilot.app/Contents/Resources/shell/bin/ccp' add work")
        try expectEqual(c.removeCommand("a.b_c-d"), "'/Applications/CC Pilot.app/Contents/Resources/shell/bin/ccp' rm a.b_c-d")

        try FileManager.default.copyItem(at: repoRoot.appendingPathComponent("shell"),
                                         to: home.url.appendingPathComponent(".cc-pilot"))
        try expectEqual(c.addCommand("work"), "~/.cc-pilot/bin/ccp add work")
        try expectEqual(c.removeCommand("work"), "~/.cc-pilot/bin/ccp rm work")
        // 终端里的 shell 会展开 ~，执行的就是已安装的 ccp
        let result = try typeInTerminal(home, c.addCommand("work"), extraEnvironment: fakeClaude(home))
        try expectEqual(result.status, 0, "执行已安装的 ccp add 的退出码（stderr：\(result.err)）")
        try expect(FileManager.default.fileExists(atPath: home.profilesRoot.appendingPathComponent("work").path),
                   "应已创建档案 work")
    }

    static func removalBlockers() throws {
        try expectEqual(ProfileCommands.removalBlocker(profile: "default", currentProfile: "work"), .defaultProfile)
        try expectEqual(ProfileCommands.removalBlocker(profile: "default", currentProfile: "default"), .defaultProfile)
        try expectEqual(ProfileCommands.removalBlocker(profile: "work", currentProfile: "work"), .currentProfile)
        try expectEqual(ProfileCommands.removalBlocker(profile: "work", currentProfile: "default"), nil)
        try expectEqual(ProfileCommands.removalBlocker(profile: "work", currentProfile: "personal"), nil)

        // ccp rm 对同样的档案也拒绝，而且在确认之前就拒绝（不读标准输入、不启动 Claude Code）
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        try home.write(".claude-profiles/active", "work\n")
        for name in ["default", "work"] {
            let result = try ShellRun.run(home, [bundledCcp.path, "rm", name], extraEnvironment: fakeClaude(home),
                                          stdin: "y\n")
            try expect(result.status != 0, "ccp rm \(name) 应被拒绝")
        }
        try expect(!FileManager.default.fileExists(atPath: home.root.appendingPathComponent("claude-log").path),
                   "被拒绝时不应启动 Claude Code")
        try expect(FileManager.default.fileExists(atPath: home.profilesRoot.appendingPathComponent("work").path),
                   "当前档案 work 不应被删除")
    }

    static func removeCommandDeletesLoggedOutProfile() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfile("work", config: claudeConfig(uuid: "u-w", email: "w@example.com"))
        let line = commands(home).removeCommand("work")

        // 用户在确认提示里回答 y；假钥匙串里没有这个档案的项，相当于已在 Claude Code 里 /logout
        let result = try typeInTerminal(home, line, extraEnvironment: fakeClaude(home), stdin: "y\n")

        try expectEqual(result.status, 0, "执行 \(line) 的退出码（stderr：\(result.err)）")
        let names = ProfileStore(environment: home.environment).listProfiles().map(\.name)
        try expectEqual(names, ["default"])
    }

    static func removeCommandKeepsSignedInProfile() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfile("work", config: claudeConfig(uuid: "u-w", email: "w@example.com"))
        let service = KeychainServiceName.forConfigDir(home.profilesRoot.appendingPathComponent("work").path)
        try home.keychainItem(service: service, "{}")
        let line = commands(home).removeCommand("work")

        let result = try typeInTerminal(home, line, extraEnvironment: fakeClaude(home), stdin: "y\n")

        try expect(result.status != 0 && result.err.contains("仍处于登录状态"),
                   "仍在登录时 ccp rm 应以登录状态为由拒绝（stderr：\(result.err)）")
        let names = ProfileStore(environment: home.environment).listProfiles().map(\.name)
        try expectEqual(names, ["default", "work"])
    }
}
