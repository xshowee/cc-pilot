// ticket 07：App 核心的"切换"。写入当前档案记录的格式必须与 `ccp use` 完全相同：
// 档案名加一个换行，切回默认档案时写 "default\n"（不删除记录）；同目录临时文件 + rename。

import Foundation

final class ProfileSwitchChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("切换到某个档案后，当前档案记录是档案名加一个换行", switchWritesNameAndNewline),
            Check("切换到默认档案写入 default 加一个换行，不删除记录", switchToDefaultWritesDefault),
            Check("切换后 shell 库读出的当前档案就是新名字", shellReadsSwitchedName),
            Check("切换后真实的 ccp current 输出新名字", ccpCurrentReadsSwitchedName),
            Check("名字不合规、是保留名或档案不存在时拒绝切换，记录保持不变", refusesBadTargets),
            Check("记录的位置是目录时拒绝切换", refusesWhenRecordIsDirectory),
            Check("档案根目录还不存在时切换到默认档案会创建它", switchCreatesProfilesRoot),
            Check("写入的记录与 ccp use 按字节、权限都相同", matchesCcpUseBytes),
            Check("读取当前档案与 shell 的规则相同", readsLikeShell),
        ]
    }

    private static func record(_ home: TempHome) -> URL {
        home.profilesRoot.appendingPathComponent("active")
    }

    private static func recordBytes(_ home: TempHome) -> Data? {
        try? Data(contentsOf: record(home))
    }

    static func switchWritesNameAndNewline() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")

        try CurrentProfileRecord(environment: home.environment).switchTo("work")

        try expectEqual(recordBytes(home), Data("work\n".utf8))
    }

    static func switchToDefaultWritesDefault() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        try home.write(".claude-profiles/active", "work\n")

        try CurrentProfileRecord(environment: home.environment).switchTo("default")

        try expectEqual(recordBytes(home), Data("default\n".utf8))
    }

    private static func shellActiveName(_ home: TempHome) throws -> String {
        try ShellRun.zsh(home, "source \"$1/shell/lib/profiles.zsh\" && _ccp_active_name", repoRoot.path).out
    }

    static func shellReadsSwitchedName() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        let switcher = CurrentProfileRecord(environment: home.environment)

        try switcher.switchTo("work")
        try expectEqual(try shellActiveName(home), "work\n")
        try switcher.switchTo("default")
        try expectEqual(try shellActiveName(home), "default\n")
    }

    static func ccpCurrentReadsSwitchedName() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        let switcher = CurrentProfileRecord(environment: home.environment)
        let ccp = repoRoot.appendingPathComponent("shell/bin/ccp").path

        for name in ["work", "default"] {
            try switcher.switchTo(name)
            let result = try ShellRun.run(home, [ccp, "current"])
            try expectEqual(result.status, 0, "ccp current 的退出码（stderr：\(result.err)）")
            try expectEqual(result.out, name + "\n")
        }
    }

    /// 档案根目录下除档案目录和记录以外的条目（检查有没有遗留临时文件）
    private static func strayEntries(_ home: TempHome, besides keep: Set<String>) -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: home.profilesRoot.path)) ?? []
        return entries.filter { !keep.contains($0) }.sorted()
    }

    static func refusesBadTargets() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        try home.write(".claude-profiles/a-file", "not a profile")
        try home.write(".claude-profiles/active", "work\n")
        let switcher = CurrentProfileRecord(environment: home.environment)

        let cases: [(String, CurrentProfileRecord.SwitchError)] = [
            ("", .invalidName), ("-x", .invalidName), (".hidden", .invalidName), ("a b", .invalidName),
            ("../work", .invalidName), ("ｗork", .invalidName), ("active", .invalidName),
            ("missing", .profileMissing), ("a-file", .profileMissing),
        ]
        for (name, expected) in cases {
            do {
                try switcher.switchTo(name)
                throw CheckFailure(description: "切换到 \"\(name)\" 应当失败")
            } catch let error as CurrentProfileRecord.SwitchError {
                try expectEqual(error, expected, "切换到 \"\(name)\"")
            }
            try expectEqual(recordBytes(home), Data("work\n".utf8), "切换到 \"\(name)\" 失败后的记录")
        }
        try expectEqual(strayEntries(home, besides: ["work", "a-file", "active"]), [])
    }

    static func refusesWhenRecordIsDirectory() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        try home.makeProfileDir("active")   // 记录的位置被一个目录占了

        do {
            try CurrentProfileRecord(environment: home.environment).switchTo("work")
            throw CheckFailure(description: "记录的位置是目录时应当拒绝")
        } catch let error as CurrentProfileRecord.SwitchError {
            try expectEqual(error, .recordIsDirectory)
        }
        try expectEqual(try FileManager.default.contentsOfDirectory(
            atPath: home.profilesRoot.appendingPathComponent("active").path), [], "目录里不应被放进文件")
        try expectEqual(strayEntries(home, besides: ["work", "active"]), [])
    }

    static func switchCreatesProfilesRoot() throws {
        let home = try TempHome()
        defer { home.remove() }

        try CurrentProfileRecord(environment: home.environment).switchTo("default")

        try expectEqual(recordBytes(home), Data("default\n".utf8))
        try expectEqual(strayEntries(home, besides: ["active"]), [])
    }

    private static func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    static func matchesCcpUseBytes() throws {
        let ccp = repoRoot.appendingPathComponent("shell/bin/ccp").path
        for name in ["work", "default"] {
            let viaApp = try TempHome(), viaShell = try TempHome()
            defer { viaApp.remove(); viaShell.remove() }
            for home in [viaApp, viaShell] {
                try home.makeProfileDir("work")
                try home.makeProfileDir("other")
                try home.write(".claude-profiles/active", "other\n")
            }

            try CurrentProfileRecord(environment: viaApp.environment).switchTo(name)
            let result = try ShellRun.run(viaShell, [ccp, "use", name])
            try expectEqual(result.status, 0, "ccp use \(name) 的退出码（stderr：\(result.err)）")

            try expectEqual(recordBytes(viaApp), recordBytes(viaShell), "切换到 \(name) 的记录内容")
            try expectEqual(try permissions(record(viaApp)), try permissions(record(viaShell)),
                            "切换到 \(name) 的记录权限")
            try expectEqual(strayEntries(viaApp, besides: ["work", "other", "active"]),
                            strayEntries(viaShell, besides: ["work", "other", "active"]))
        }
    }

    static func readsLikeShell() throws {
        let home = try TempHome()
        defer { home.remove() }
        let reader = CurrentProfileRecord(environment: home.environment)

        try expectEqual(reader.currentName(), "default", "档案根目录不存在")
        try home.makeProfileDir("work")
        try expectEqual(reader.currentName(), "default", "记录不存在")

        let cases: [(String, String)] = [
            ("work\n", "work"), ("work", "work"), ("work\r\n", "work"), ("  work \t\n", "work"),
            ("", "default"), ("\n", "default"), ("   \n", "default"), ("default\n", "default"),
            ("work\nother\n", "work"), ("\nwork\n", "default"),
            ("no such profile\n", "no such profile"), ("../x\n", "../x"),
        ]
        for (content, expected) in cases {
            try home.write(".claude-profiles/active", content)
            try expectEqual(reader.currentName(), expected, "记录内容 \(content.debugDescription)")
            // 独立的事实来源：shell 库自己的读取逻辑
            try expectEqual(try shellActiveName(home), expected + "\n",
                            "shell 读取记录内容 \(content.debugDescription)")
        }
    }
}
