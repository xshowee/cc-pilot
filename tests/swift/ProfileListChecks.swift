// ticket 06：App 核心"列出档案"（ProfileStore.listProfiles）。

import Foundation

final class ProfileListChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("空主目录只有默认档案，且未登录", emptyHomeHasOnlyDefault),
            Check("默认档案读 $HOME/.claude.json 的账号资料", defaultProfileReadsHomeClaudeJSON),
            Check("其他档案排在默认档案之后，按名字排序", listsOtherProfilesAfterDefault),
            Check("档案顺序与 ccp ls 相同（按字节序）", ordersLikeCcpLs),
            Check("名字不合规的目录、保留名、当前档案记录、临时文件都不是档案", ignoresNonProfileEntries),
            Check("指向目录的软链接算档案，悬空软链接不算", followsSymlinkedProfileDirs),
            Check("按 accountUuid 标出登录同一账号的其他档案", marksProfilesSharingAnAccount),
            Check("列出档案不创建、不修改任何文件", listingIsReadOnly),
        ]
    }

    static func emptyHomeHasOnlyDefault() throws {
        let home = try TempHome()
        defer { home.remove() }
        let profiles = ProfileStore(environment: home.environment).listProfiles()
        try expectEqual(profiles.map(\Profile.name), ["default"])
        try expect(profiles[0].isDefault, "默认档案应标记为 isDefault")
        try expectEqual(profiles[0].account, .loggedOut)
    }

    static func defaultProfileReadsHomeClaudeJSON() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.writeDefaultConfig(claudeConfig(
            uuid: "uuid-a", email: "a@example.com", orgName: "Acme",
            orgType: "claude_max", rateLimitTier: "default_claude_max_20x"))
        // ~/.claude/.claude.json 不是默认档案的配置文件，不应被读取
        try home.writeJSON(".claude/.claude.json", claudeConfig(uuid: "wrong", email: "wrong@example.com"))

        let profiles = ProfileStore(environment: home.environment).listProfiles()
        try expectEqual(profiles.count, 1)
        try expectEqual(profiles[0].configDir, nil)
        try expectEqual(profiles[0].account, .loggedIn(Account(
            accountUuid: "uuid-a", email: "a@example.com", organizationName: "Acme",
            tier: .max(multiplier: 20))))
    }

    static func listsOtherProfilesAfterDefault() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.writeDefaultConfig(claudeConfig(uuid: "uuid-d", email: "d@example.com"))
        try home.makeProfile("work", config: claudeConfig(
            uuid: "uuid-w", email: "w@corp.example", orgName: "Corp", orgType: "claude_team"))
        try home.makeProfile("personal", config: claudeConfig(
            uuid: "uuid-p", email: "p@example.com", orgType: "claude_pro"))
        try home.makeProfileDir("fresh")   // 刚建好、还没有 .claude.json

        let profiles = ProfileStore(environment: home.environment).listProfiles()
        try expectEqual(profiles.map(\Profile.name), ["default", "fresh", "personal", "work"])

        let work = profiles[3]
        try expect(!work.isDefault, "work 不是默认档案")
        try expectEqual(work.configDir, home.url.path + "/.claude-profiles/work")
        try expectEqual(work.account, .loggedIn(Account(
            accountUuid: "uuid-w", email: "w@corp.example", organizationName: "Corp", tier: .team)))
        try expectEqual(profiles[2].account.account?.tier, .pro)
        try expectEqual(profiles[1].account, .loggedOut)
    }

    static func ordersLikeCcpLs() throws {
        let home = try TempHome()
        defer { home.remove() }
        // 不分大小写的文件系统上 b 和 B 不能同时存在，所以用首字母各不相同的名字
        for name in ["zed", "Alpha", "beta", "Carol", "1x", "a-b", "a_b", "a.b", "A9"] {
            try home.makeProfileDir(name)
        }
        let expected = ["default", "1x", "A9", "Alpha", "Carol", "a-b", "a.b", "a_b", "beta", "zed"]

        let names = ProfileStore(environment: home.environment).listProfiles().map(\Profile.name)
        try expectEqual(names, expected)

        let ccp = repoRoot.appendingPathComponent("shell/bin/ccp").path
        let result = try ShellRun.run(home, [ccp, "ls"])
        try expectEqual(result.status, 0, "ccp ls 的退出码（stderr：\(result.err)）")
        let listed = result.out.split(separator: "\n").map { String($0.dropFirst(2)) }
        try expectEqual(listed, expected, "ccp ls 的顺序")
    }

    static func ignoresNonProfileEntries() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("ok.1_a-b")
        try home.write(".claude-profiles/active", "ok.1_a-b\n")          // 当前档案记录
        try home.write(".claude-profiles/active.tmp.12345", "x\n")       // 原子写入的临时文件
        try home.write(".claude-profiles/.DS_Store", "")
        try home.write(".claude-profiles/notes", "名字合规但不是目录\n")
        for bad in ["-bad", ".hidden", "bad name", "中文", "default", "work\u{FF41}"] {
            try home.makeProfileDir(bad)
        }

        var names = ProfileStore(environment: home.environment).listProfiles().map(\Profile.name)
        try expectEqual(names, ["default", "ok.1_a-b"])

        // 名为 active 的目录也不是档案（保留名）
        let other = try TempHome()
        defer { other.remove() }
        try other.makeProfileDir("active")
        names = ProfileStore(environment: other.environment).listProfiles().map(\Profile.name)
        try expectEqual(names, ["default"])
    }

    static func followsSymlinkedProfileDirs() throws {
        let home = try TempHome()
        defer { home.remove() }
        let target = home.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try home.makeProfileDir("real")
        try FileManager.default.createSymbolicLink(
            at: home.profilesRoot.appendingPathComponent("linked"), withDestinationURL: target)
        try FileManager.default.createSymbolicLink(
            at: home.profilesRoot.appendingPathComponent("dangling"),
            withDestinationURL: home.root.appendingPathComponent("missing"))

        let names = ProfileStore(environment: home.environment).listProfiles().map(\Profile.name)
        try expectEqual(names, ["default", "linked", "real"])
    }

    static func marksProfilesSharingAnAccount() throws {
        let home = try TempHome()
        defer { home.remove() }
        // default、b、d 是同一账号（accountUuid 相同；邮箱大小写不同也不影响）
        try home.writeDefaultConfig(claudeConfig(uuid: "same", email: "me@example.com"))
        try home.makeProfile("b", config: claudeConfig(uuid: "same", email: "Me@Example.com"))
        try home.makeProfile("d", config: claudeConfig(uuid: "same", email: "me@example.com"))
        // c 与 default 邮箱相同但 accountUuid 不同：不是同一账号
        try home.makeProfile("c", config: claudeConfig(uuid: "other", email: "me@example.com"))
        // 没有 accountUuid 的不参与判断；未登录的也不参与
        try home.makeProfile("e", config: claudeConfig(uuid: nil, email: "me@example.com"))
        try home.makeProfileDir("f")

        let profiles = ProfileStore(environment: home.environment).listProfiles()
        let same = Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0.sameAccountAs) })
        try expectEqual(same["default"], ["b", "d"])
        try expectEqual(same["b"], ["default", "d"])
        try expectEqual(same["d"], ["default", "b"])
        try expectEqual(same["c"], [])
        try expectEqual(same["e"], [])
        try expectEqual(same["f"], [])
    }

    static func listingIsReadOnly() throws {
        // 主目录里什么都没有时，不应创建 ~/.claude-profiles 或 ~/.claude.json
        let empty = try TempHome()
        defer { empty.remove() }
        _ = ProfileStore(environment: empty.environment).listProfiles()
        try expectEqual(try snapshot(empty), [:])

        let home = try TempHome()
        defer { home.remove() }
        try home.writeDefaultConfig(claudeConfig(uuid: "u", email: "a@example.com"))
        try home.makeProfile("work", config: claudeConfig(uuid: "v", email: "b@example.com"))
        try home.makeProfileDir("fresh")
        try home.write(".claude-profiles/active", "work\n")
        let before = try snapshot(home)
        _ = ProfileStore(environment: home.environment).listProfiles()
        try expectEqual(try snapshot(home), before)
    }

    /// 主目录下所有条目的 相对路径 → (修改时间, 大小)
    private static func snapshot(_ home: TempHome) throws -> [String: String] {
        var result: [String: String] = [:]
        let base = home.url.resolvingSymlinksInPath().path
        guard let e = FileManager.default.enumerator(atPath: base) else { return [:] }
        for case let rel as String in e {
            let attrs = try FileManager.default.attributesOfItem(atPath: base + "/" + rel)
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            result[rel] = "\(mtime) \(attrs[.size] ?? 0)"
        }
        return result
    }
}
