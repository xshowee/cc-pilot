// ticket 10：App 核心自己计算钥匙串 service 名，并与 ticket 01 的 shell 函数 _ccp_service_name 一致。
// 期望值来自两端共用的测试向量 tests/fixtures/service-names.tsv，同时实际调用 shell 函数对比。
// 注意：Swift 的 String == 按规范等价比较（NFD 与 NFC 相等），所以一律比较 UTF-8 字节。

import Foundation

final class ServiceNameChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("对测试向量的每一行，App 核心与 shell 函数都得到期望的 service 名", fixtureVectors),
            Check("NFD 形式的非 ASCII 主目录下的档案，两端算出的 service 名相同", nfdHomeProfile),
            Check("结尾带 / 的路径与不带的结果不同，两端一致", trailingSlash),
            Check("档案列表里每个档案的 service 名与 shell 按同一 HOME 算出的相同", profilesMatchShell),
        ]
    }

    struct Vector {
        /// nil 表示默认档案（不设置 CLAUDE_CONFIG_DIR）
        let configDir: String?
        let expected: String
        let note: String
    }

    static func vectors() throws -> [Vector] {
        let url = repoRoot.appendingPathComponent("tests/fixtures/service-names.tsv")
        let text = try String(contentsOf: url, encoding: .utf8)
        var result: [Vector] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            try expect(cols.count >= 2, "测试向量格式不对：\(line)")
            let dir: String?
            if cols[0] == "-" {
                dir = nil
            } else {
                guard let bytes = decodeHex(cols[0]) else { throw CheckFailure(description: "十六进制不对：\(cols[0])") }
                dir = String(decoding: bytes, as: UTF8.self)
            }
            result.append(Vector(configDir: dir, expected: cols[1], note: cols.count > 2 ? cols[2] : ""))
        }
        try expect(result.count >= 6, "测试向量太少：\(result.count)")
        return result
    }

    static func fixtureVectors() throws {
        for v in try vectors() {
            try expectSameBytes(KeychainServiceName.forConfigDir(v.configDir), v.expected, "App 核心：\(v.note)")
            try expectSameBytes(try shellServiceName(v.configDir), v.expected, "shell：\(v.note)")
        }
        // 向量里 NFD 那一行确实是 NFD 字节（防止测试数据被意外规范化）
        let nfd = try vectors().compactMap(\.configDir).first { $0.utf8.contains(0xCC) }
        try expect(nfd != nil, "测试向量里应有一行 NFD 形式的路径")
    }

    static func nfdHomeProfile() throws {
        let nfd = "/Users/Jose\u{301}/.claude-profiles/work"
        let nfc = "/Users/Jos\u{E9}/.claude-profiles/work"
        try expect(Array(nfd.utf8) != Array(nfc.utf8), "测试数据本身应有 NFD/NFC 之分")
        let a = KeychainServiceName.forConfigDir(nfd)
        let b = KeychainServiceName.forConfigDir(nfc)
        try expectSameBytes(a, b, "NFD 与 NFC 写法")
        try expectSameBytes(a, "Claude Code-credentials-7959c412", "NFD 写法")
        try expectSameBytes(try shellServiceName(nfd), a, "shell 与 App 核心（NFD）")
    }

    static func trailingSlash() throws {
        let plain = "/Users/test/.claude-profiles/work"
        let slash = plain + "/"
        try expect(Array(KeychainServiceName.forConfigDir(plain).utf8)
                   != Array(KeychainServiceName.forConfigDir(slash).utf8), "结尾带 / 应得到不同的结果")
        try expectSameBytes(try shellServiceName(slash), KeychainServiceName.forConfigDir(slash), "结尾带 /")
    }

    static func profilesMatchShell() throws {
        // 主目录名含 NFD 字符和空格；默认档案 + 一个普通档案
        let home = try TempHome(homeName: "Jose\u{301} home")
        defer { home.remove() }
        try home.makeProfileDir("work")
        let profiles = ProfileStore(environment: home.environment).listProfiles()
        try expectEqual(profiles.map(\.name), ["default", "work"])
        try expect(profiles[1].configDir?.utf8.contains(0xCC) == true, "档案目录字符串应保留 NFD 字节")
        for p in profiles {
            let shell = try runShell(home: home.url.path, """
                source "$1/shell/lib/profiles.zsh" && source "$1/shell/lib/keychain.zsh" || exit 98
                if [[ $2 == default ]]; then _ccp_service_name; else _ccp_service_name "$(_ccp_profile_dir $2)"; fi
                """, [repoRoot.path, p.name])
            try expectSameBytes(p.keychainService, shell, "档案 \(p.name)")
        }
        try expectSameBytes(profiles[0].keychainService, "Claude Code-credentials", "默认档案")
    }

    // MARK: - 辅助

    /// 调用 shell/lib/keychain.zsh 的 _ccp_service_name（nil 表示不带参数）
    static func shellServiceName(_ configDir: String?) throws -> String {
        try runShell(home: nil, """
            source "$1/shell/lib/keychain.zsh" || exit 98
            shift
            _ccp_service_name "$@"
            """, [repoRoot.path] + (configDir.map { [$0] } ?? []))
    }

    /// 用 zsh -f 运行一段脚本，返回去掉结尾换行的 stdout；退出码非零或 stderr 非空时失败
    static func runShell(home: String?, _ script: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", script, "_"] + args
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        if let home { env["HOME"] = home }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let errText = String(decoding: errData, as: UTF8.self)
        try expect(p.terminationStatus == 0 && errText.isEmpty,
                   "shell 失败（\(p.terminationStatus)）：\(errText)")
        var s = String(decoding: data, as: UTF8.self)
        if s.hasSuffix("\n") { s.removeLast() }
        return s
    }
}

/// 按 UTF-8 字节比较两个字符串（不用 ==，见文件开头的说明）
func expectSameBytes(_ actual: String, _ expected: String, _ message: @autoclosure () -> String = "",
                     file: StaticString = #fileID, line: UInt = #line) throws {
    if Array(actual.utf8) != Array(expected.utf8) {
        throw CheckFailure(description: "\(file):\(line): \(message())：得到 [\(actual)]，期望 [\(expected)]")
    }
}

/// 十六进制字符串 → 字节；格式不对时返回 nil
func decodeHex(_ hex: String) -> [UInt8]? {
    let chars = Array(hex.utf8)
    guard chars.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    var i = 0
    while i < chars.count {
        guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
        bytes.append(b)
        i += 2
    }
    return bytes
}
