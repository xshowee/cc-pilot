// ticket 10：凭据不外泄，App 核心对凭据只读。
// 逐一检查：返回值和错误的文字形式（description / debugDescription / dump）、本进程的 stdout 和 stderr
// （核心若打印日志会出现在这里）、子进程的命令行参数（假 security 的调用记录）、磁盘上的所有文件。
// 搜索的是哨兵令牌的原文，以及它的小写、大写十六进制形式。

import Foundation

final class CredentialSafetyChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("凭据不出现在返回值、错误、日志、子进程参数和磁盘文件里", noLeaks),
            Check("App 核心从不写入、删除或续期凭据，也不写任何文件", readOnly),
            Check("检查程序注入的 security 是临时目录里的假程序，不是真的", checksNeverUseRealSecurity),
        ]
    }

    /// 各种情况各来一个档案：可以请求、十六进制、待续期、需重新登录、不支持、格式无法识别（内容里带令牌）
    static func prepare(_ home: TempHome) throws {
        let cases: [(String, String)] = [
            ("ok", credentialJSON()),
            ("hex", hexEncoded(credentialJSON(extra: ["note": "名字"]))),
            ("renew", credentialJSON(expiresAt: ms(-60))),
            ("relogin", credentialJSON(refreshExpiresAt: ms(-60))),
            ("unsupported", credentialJSON(scopes: ["user:inference"])),
            ("garbled", "oops " + Sentinel.accessToken + " " + Sentinel.refreshToken),
            ("wrongshape", #"{"accessToken":"\#(Sentinel.accessToken)","refreshToken":"\#(Sentinel.refreshToken)"}"#),
        ]
        for (i, (name, content)) in cases.enumerated() {
            let svc = try home.makeLoggedInProfile(name, uuid: "u\(i)")
            try home.keychainItem(service: svc, account: "root", content)
        }
        let svc = try home.makeLoggedInProfile("default", uuid: "u-default")
        try home.keychainItem(service: svc, credentialJSON())
    }

    static func noLeaks() throws {
        let home = try TempHome()
        defer { home.remove() }
        try prepare(home)

        var texts: [String] = []
        var granted = 0
        let log = home.root.appendingPathComponent("captured-output.log")
        try capturingOutput(to: log) {
            let checker = LoginChecker(environment: home.environment)
            let profiles = checker.withLoginStates(
                ProfileStore(environment: home.environment).listProfiles(), now: fixedNow)
            for p in profiles {
                let auth = checker.usageAuthorization(for: p, now: fixedNow)
                if case .granted(let credential) = auth {
                    granted += 1
                    texts += renderings(credential)
                }
                texts += renderings(p) + renderings(p.login as Any) + renderings(auth)
            }
            texts += renderings(profiles)
        }
        // ok、hex、default 三个档案能拿到令牌（确认确实读到了凭据，泄露检查才有意义）
        try expectEqual(granted, 3, "拿到令牌的档案数")

        // 1. 返回值、错误的文字形式
        for t in texts { try expectNoSentinel(Data(t.utf8), "返回值的文字形式：\(t.prefix(200))") }
        // 2. 本进程的 stdout / stderr
        try expectNoSentinel(try Data(contentsOf: log), "App 核心的输出（日志）")
        // 3. 子进程的命令行参数
        let calls = try home.securityCalls()
        try expect(!calls.isEmpty, "应调用过 security")
        for args in calls { try expectNoSentinel(Data(args.joined(separator: "\n").utf8), "security 的参数 \(args)") }
        // 4. 磁盘上的文件：临时根目录下除了测试自己准备的钥匙串项以外的所有文件（含主目录、调用记录）
        let items = home.fakeSecurityDir.appendingPathComponent("items").path
        var scanned = 0
        for file in try allFiles(under: home.root) where !file.hasPrefix(items + "/") {
            try expectNoSentinel(try Data(contentsOf: URL(fileURLWithPath: file)), "文件 \(file)")
            scanned += 1
        }
        try expect(scanned > 10, "扫描的文件太少：\(scanned)")
        // 对照：同样的搜索在钥匙串项里能找到令牌（原文和十六进制都能），说明搜索本身有效
        let found = try allFiles(under: URL(fileURLWithPath: items))
            .filter { containsSentinel(try Data(contentsOf: URL(fileURLWithPath: $0))) }
        try expect(found.contains { $0.hasSuffix("/root") } && found.count >= 7, "对照搜索没有找到令牌：\(found)")
    }

    static func readOnly() throws {
        let home = try TempHome()
        defer { home.remove() }
        try prepare(home)
        try home.write(".claude-profiles/active", "ok\n")
        let before = try snapshot(home.root)

        let checker = LoginChecker(environment: home.environment)
        let profiles = checker.withLoginStates(ProfileStore(environment: home.environment).listProfiles(), now: fixedNow)
        for p in profiles { _ = checker.usageAuthorization(for: p, now: fixedNow) }

        // 只调用过 find-generic-password，选项只有 -s、-a、-w
        let calls = try home.securityCalls()
        try expect(calls.count >= profiles.count, "每个已登录档案都应查询过钥匙串")
        for args in calls {
            try expectEqual(args.first, "find-generic-password", "\(args)")
            var rest = args.dropFirst()
            while let opt = rest.first {
                try expect(["-s", "-a", "-w"].contains(opt), "意外的选项 \(opt)：\(args)")
                rest = rest.dropFirst(opt == "-w" ? 1 : 2)
            }
        }
        // 除了假 security 自己写的调用记录，磁盘上没有任何变化（钥匙串项、主目录都原样）
        var after = try snapshot(home.root)
        let callsDir = home.fakeSecurityDir.appendingPathComponent("calls").path
        after = after.filter { !$0.key.hasPrefix(callsDir) }
        try expectEqual(after, before.filter { !$0.key.hasPrefix(callsDir) })
    }

    static func checksNeverUseRealSecurity() throws {
        let home = try TempHome()
        defer { home.remove() }
        let path = home.environment.security.path
        try expect(path != "/usr/bin/security" && path.hasPrefix(home.root.path + "/"), "security 路径：\(path)")
        let wrapper = try String(contentsOf: home.environment.security, encoding: .utf8)
        try expect(wrapper.contains(repoRoot.appendingPathComponent("tests/fakes/security").path),
                   "包装脚本应调用 tests/fakes/security")
    }

    // MARK: - 辅助

    static func renderings(_ value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), dumped]
    }

    static func sentinelForms() -> [Data] {
        Sentinel.all.flatMap { s in
            [Data(s.utf8), Data(hexEncoded(s).utf8), Data(hexEncoded(s, uppercase: true).utf8)]
        }
    }

    static func containsSentinel(_ data: Data) -> Bool {
        sentinelForms().contains { data.range(of: $0) != nil }
    }

    static func expectNoSentinel(_ data: Data, _ what: @autoclosure () -> String,
                                 file: StaticString = #fileID, line: UInt = #line) throws {
        try expect(!containsSentinel(data), "\(what()) 里出现了凭据", file: file, line: line)
    }

    static func allFiles(under root: URL) throws -> [String] {
        let base = root.resolvingSymlinksInPath().path
        guard let e = FileManager.default.enumerator(atPath: base) else { return [] }
        var files: [String] = []
        for case let rel as String in e {
            let path = base + "/" + rel
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                files.append(path)
            }
        }
        return files
    }

    /// 路径 → (修改时间, 大小, 内容)
    static func snapshot(_ root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in try allFiles(under: root) {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            result[path] = "\(mtime) \(attrs[.size] ?? 0) \(data.base64EncodedString())"
        }
        return result
    }

    /// 运行 body 期间把本进程的 stdout、stderr 重定向到文件
    static func capturingOutput(to file: URL, _ body: () throws -> Void) throws {
        fflush(stdout)
        fflush(stderr)
        let fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        try expect(fd >= 0, "无法创建 \(file.path)")
        let saved = (dup(1), dup(2))
        dup2(fd, 1)
        dup2(fd, 2)
        defer {
            fflush(stdout)
            fflush(stderr)
            dup2(saved.0, 1)
            dup2(saved.1, 2)
            close(saved.0)
            close(saved.1)
            close(fd)
        }
        try body()
    }
}
