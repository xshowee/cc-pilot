// chatgpt-profiles ticket 05：App 添加 ChatGPT 档案（App 核心 ChatGPTProfileCommands）。
// App 自己不建档案：提交前检查档案名，拼出交给终端执行的 `ccp chatgpt add <名字>`。
// 档案名规则的期望值与 tests/shell/test-ccp-chatgpt-add.zsh 一致，并且用真实的 ccp chatgpt add 交叉验证
// （codex 一律是假的 tests/fakes/codex，见 fakeCodex）。

import Foundation

final class ChatGPTProfileCommandChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("ChatGPT 新档案名：不合规、保留名、已存在时给出对应的问题", newNameProblems),
            Check("ChatGPT 新档案名的判断与真实的 ccp chatgpt add 一致", newNameAgreesWithCcpChatgptAdd),
            Check("ChatGPT 添加命令：在终端里执行并登录后，新档案出现在列表里并带邮箱", addCommandLeadsToSignedInProfile),
            Check("ChatGPT 命令文字：装了 ~/.cc-pilot 用它，没装用 App 内置的 ccp", commandText),
            Check("进行中的 ChatGPT 添加在新档案登录后结束", pendingChangeFinishes),
        ]
    }

    static func commands(_ home: TempHome) -> ChatGPTProfileCommands {
        ChatGPTProfileCommands(environment: home.environment, bundledCcp: ProfileCommandChecks.bundledCcp)
    }

    /// 假 codex 的环境：记录目录放在临时根目录里；authJSON 是 codex login 写入的 auth.json 的来源文件
    static func fakeCodex(_ home: TempHome, authJSON: URL? = nil) -> [String: String] {
        var env = ["FAKE_CODEX_LOG_DIR": home.root.appendingPathComponent("codex-log").path]
        if let authJSON { env["FAKE_CODEX_AUTH_JSON"] = authJSON.path }
        return env
    }

    static func newNameProblems() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        try home.makeCodexProfile("work")
        try home.write(".codex-profiles/stray-file", "x")
        try FileManager.default.createSymbolicLink(atPath: home.codexProfilesRoot.appendingPathComponent("dangling").path,
                                                   withDestinationPath: home.url.appendingPathComponent("nowhere").path)
        try home.makeProfileDir("claude-only")
        let c = commands(home)

        try expectEqual(c.newNameProblem(""), .empty)
        for bad in ["-x", ".hidden", "_a", "a b", "a/b", "名字", "ａ", "a\n", " a"] {
            try expectEqual(c.newNameProblem(bad), .malformed, "名字 \(bad.debugDescription)")
        }
        try expectEqual(c.newNameProblem("default"), .reserved)
        try expectEqual(c.newNameProblem("active"), .reserved)
        try expectEqual(c.newNameProblem("work"), .exists)
        try expectEqual(c.newNameProblem("stray-file"), .exists, "同名的文件也算已存在（与 ccp chatgpt add 一致）")
        try expectEqual(c.newNameProblem("dangling"), .exists, "悬空的软链接也算已存在")
        try expectEqual(c.newNameProblem("claude-only"), nil, "只有同名的 Claude 档案时可以新建（两个工具可以同名）")
        for good in ["personal", "Work2", "a.b_c-d", "9"] {
            try expectEqual(c.newNameProblem(good), nil, "名字 \(good)")
        }
    }

    static func newNameAgreesWithCcpChatgptAdd() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        try home.makeCodexProfile("work")
        let ccp = ProfileCommandChecks.bundledCcp.path
        let names = ["", "-x", ".hidden", "a b", "名字", "default", "active", "work", "personal", "a.b_c-d"]
        for name in names {
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: home.codexProfilesRoot.path))
            let appSays = commands(home).newNameProblem(name)
            let result = try ShellRun.run(home, [ccp, "chatgpt", "add", name], extraEnvironment: fakeCodex(home))
            let created = Set(try FileManager.default.contentsOfDirectory(atPath: home.codexProfilesRoot.path))
                .subtracting(before)
            if let appSays {
                try expect(result.status != 0, "App 拒绝 \(name.debugDescription)（\(appSays)），ccp chatgpt add 却成功了")
                try expectEqual(created, [], "ccp chatgpt add 拒绝 \(name.debugDescription) 时不应创建任何东西")
            } else {
                try expectEqual(result.status, 0,
                                "App 认为 \(name.debugDescription) 可以新建，ccp chatgpt add 却失败了：\(result.err)")
                try expectEqual(created, [name])
            }
        }
    }

    static func addCommandLeadsToSignedInProfile() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        // 假 codex login 写入的 auth.json：真实形状的 ChatGPT 登录
        let auth = home.root.appendingPathComponent("login-auth.json")
        try JSONSerialization.data(withJSONObject: chatgptAuth(email: "new@example.com")).write(to: auth)
        let line = commands(home).addCommand("work")

        let result = try ProfileCommandChecks.typeInTerminal(home, line,
                                                             extraEnvironment: fakeCodex(home, authJSON: auth))

        try expectEqual(result.status, 0, "执行 \(line) 的退出码（stderr：\(result.err)）")
        let work = ChatGPTProfileStore(environment: home.environment).listProfiles(now: fixedNow)
            .first { $0.name == "work" }
        try expectEqual(work?.account?.email, "new@example.com", "列表里的 work 应已登录并带邮箱")
        try expectEqual(work?.status, .canRequestUsage)
    }

    static func commandText() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        let bundled = URL(fileURLWithPath: "/Applications/CC Pilot.app/Contents/Resources/shell/bin/ccp")
        let c = ChatGPTProfileCommands(environment: home.environment, bundledCcp: bundled)

        try expectEqual(c.addCommand("work"),
                        "'/Applications/CC Pilot.app/Contents/Resources/shell/bin/ccp' chatgpt add work")

        try FileManager.default.copyItem(at: repoRoot.appendingPathComponent("shell"),
                                         to: home.url.appendingPathComponent(".cc-pilot"))
        try expectEqual(c.addCommand("a.b_c-d"), "~/.cc-pilot/bin/ccp chatgpt add a.b_c-d")
        // 终端里的 shell 会展开 ~，执行的就是已安装的 ccp
        let result = try ProfileCommandChecks.typeInTerminal(home, c.addCommand("work"),
                                                             extraEnvironment: fakeCodex(home))
        try expectEqual(result.status, 0, "执行已安装的 ccp chatgpt add 的退出码（stderr：\(result.err)）")
        try expect(ChatGPTProfilePaths.isDirectory(home.codexProfilesRoot.appendingPathComponent("work").path),
                   "应已创建 ChatGPT 档案 work")
        try expect(!FileManager.default.fileExists(atPath: home.profilesRoot.appendingPathComponent("work").path),
                   "不应创建 Claude 档案")
    }

    static func pendingChangeFinishes() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault()
        let store = ChatGPTProfileStore(environment: home.environment)
        let adding = ProfileCommands.PendingChange.adding("work")

        try expectEqual(adding.isFinished(inChatGPT: store.listProfiles(now: fixedNow)), false, "还没有档案目录")
        try home.makeCodexProfile("work")
        try expectEqual(adding.isFinished(inChatGPT: store.listProfiles(now: fixedNow)), false, "目录已建好、还没登录")
        try home.writeJSON(".codex-profiles/work/auth.json", chatgptAuth(email: "w@example.com"))
        try expectEqual(adding.isFinished(inChatGPT: store.listProfiles(now: fixedNow)), true, "登录后")
        try home.writeJSON(".codex-profiles/work/auth.json", apiKeyAuth())
        try expectEqual(adding.isFinished(inChatGPT: store.listProfiles(now: fixedNow)), true, "用 API key 登录也算完成")
    }
}
