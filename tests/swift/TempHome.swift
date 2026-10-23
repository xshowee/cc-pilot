// 检查用的临时主目录。每个检查新建一个，结束时 `remove()`（一般写在 defer 里）。
// 路径里故意带空格，和 tests/shell/lib.zsh 的 $T_HOME 一样。
//
// 钥匙串：`environment` 里的 security 一律是假的 tests/fakes/security（经 root/bin/security 包一层，
// 带上本 TempHome 自己的 FAKE_SECURITY_DIR = root/security），检查程序绝不会调用真的 /usr/bin/security。
// 用 `keychainItem(...)` 准备钥匙串项，用 `securityCalls()` 读取调用记录（格式见 tests/fakes/security）。
//
// 网络：`environment` 里的网络层一律是 `transport`（假的，见 FakeUsageTransport.swift），绝不访问真的网络。
//
// 终端：`environment` 里的 osascript 一律是假的 tests/fakes/fake-osascript（经 root/bin/osascript 包一层，
// 带上 FAKE_OSASCRIPT_DIR = root/osascript），绝不会真的打开终端或触发自动化授权弹窗。
// 用 `osascriptCalls()` 读取调用记录，`osascriptFails(exit:stderr:)` 模拟失败。

import Foundation

final class TempHome {
    /// 临时根目录（其下的 `home dir` 是主目录）
    let root: URL
    /// 作为 HOME 交给 App 核心的目录
    let url: URL

    /// 假 security 的数据目录（FAKE_SECURITY_DIR）
    let fakeSecurityDir: URL
    /// 注入给 App 核心的 security 路径（调用假 security 的包装脚本）
    let securityTool: URL
    /// 假 osascript 的数据目录（FAKE_OSASCRIPT_DIR）
    let fakeOsascriptDir: URL
    /// 注入给 App 核心的 osascript 路径（调用假 osascript 的包装脚本）
    let osascriptTool: URL
    /// 注入给 App 核心的"当前用户名"
    static let userName = "tester"
    /// 注入给 App 核心的版本号（额度请求的 User-Agent 用它）
    static let appVersion = "9.8.7-check"
    /// 注入给 App 核心的假网络层，记录所有请求
    let transport = FakeUsageTransport()

    init(homeName: String = "home dir") throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("cc-pilot-check-\(UUID().uuidString)")
        url = root.appendingPathComponent(homeName)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)

        fakeSecurityDir = root.appendingPathComponent("security")
        securityTool = root.appendingPathComponent("bin/security")
        try fm.createDirectory(at: fakeSecurityDir.appendingPathComponent("items"), withIntermediateDirectories: true)
        try fm.createDirectory(at: securityTool.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fake = repoRoot.appendingPathComponent("tests/fakes/security").path
        let wrapper = """
            #!/bin/zsh -f
            export FAKE_SECURITY_DIR=\(Self.shellQuote(fakeSecurityDir.path))
            exec \(Self.shellQuote(fake)) "$@"

            """
        try Data(wrapper.utf8).write(to: securityTool)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: securityTool.path)

        fakeOsascriptDir = root.appendingPathComponent("osascript")
        osascriptTool = root.appendingPathComponent("bin/osascript")
        try fm.createDirectory(at: fakeOsascriptDir, withIntermediateDirectories: true)
        let fakeOsascript = repoRoot.appendingPathComponent("tests/fakes/fake-osascript").path
        let osascriptWrapper = """
            #!/bin/zsh -f
            export FAKE_OSASCRIPT_DIR=\(Self.shellQuote(fakeOsascriptDir.path))
            exec \(Self.shellQuote(fakeOsascript)) "$@"

            """
        try Data(osascriptWrapper.utf8).write(to: osascriptTool)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: osascriptTool.path)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    var environment: CoreEnvironment {
        CoreEnvironment(home: url, security: securityTool, userName: Self.userName, securityTimeout: 10,
                        searchPath: searchPath, transport: transport, appVersion: Self.appVersion,
                        osascript: osascriptTool)
    }

    /// 交给 App 核心运行 shell 脚本时的 PATH：最前面是假的 security（本目录的包装）和 tests/fakes/ 里的假 claude
    var searchPath: String {
        let fakes = repoRoot.appendingPathComponent("tests/fakes").path
        return "\(securityTool.deletingLastPathComponent().path):\(fakes):/usr/bin:/bin:/usr/sbin:/sbin"
    }

    var profilesRoot: URL { url.appendingPathComponent(".claude-profiles") }

    // MARK: 准备文件

    /// 创建档案目录 ~/.claude-profiles/<名字>/（不写 .claude.json）
    func makeProfileDir(_ name: String) throws {
        try FileManager.default.createDirectory(
            at: profilesRoot.appendingPathComponent(name), withIntermediateDirectories: true)
    }

    /// 写入任意文本文件（路径相对于主目录），自动创建父目录
    func write(_ relativePath: String, _ text: String) throws {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    /// 写入 JSON 文件（路径相对于主目录）
    func writeJSON(_ relativePath: String, _ object: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try write(relativePath, String(decoding: data, as: UTF8.self))
    }

    /// 写默认档案的 ~/.claude.json
    func writeDefaultConfig(_ object: Any) throws {
        try writeJSON(".claude.json", object)
    }

    /// 创建档案目录并写入它的 .claude.json
    func makeProfile(_ name: String, config: Any) throws {
        try makeProfileDir(name)
        try writeJSON(".claude-profiles/\(name)/.claude.json", config)
    }

    // MARK: 假钥匙串

    /// 加一条钥匙串项；content 就是 `security -w` 要输出的文本（不含结尾换行，假 security 会补上）
    func keychainItem(service: String, account: String = TempHome.userName, _ content: String) throws {
        let dir = fakeSecurityDir.appendingPathComponent("items").appendingPathComponent(service)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: dir.appendingPathComponent(account))
    }

    /// 假 security 每次被调用时收到的参数，按调用顺序
    func securityCalls() throws -> [[String]] {
        Self.calls(in: fakeSecurityDir.appendingPathComponent("calls"))
    }

    // MARK: 假 osascript

    /// 假 osascript 每次被调用时收到的参数，按调用顺序
    func osascriptCalls() -> [[String]] {
        Self.calls(in: fakeOsascriptDir.appendingPathComponent("calls"))
    }

    /// 让之后的假 osascript 以 exit 退出，并往 stderr 输出 stderr
    func osascriptFails(exit: Int32, stderr: String) throws {
        try Data("\(exit)\n".utf8).write(to: fakeOsascriptDir.appendingPathComponent("exit"))
        try Data(stderr.utf8).write(to: fakeOsascriptDir.appendingPathComponent("stderr"))
    }

    /// 读取假程序的调用记录目录（calls/1、2、3……，每个参数一行 arg=<参数>）
    private static func calls(in dir: URL) -> [[String]] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        var calls: [[String]] = []
        var n = 1
        while true {
            let file = dir.appendingPathComponent(String(n))
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { break }
            calls.append(text.split(separator: "\n").filter { $0.hasPrefix("arg=") }.map { String($0.dropFirst(4)) })
            n += 1
        }
        return calls
    }
}

/// 构造一份 .claude.json：只含账号资料，外加几个与账号无关的字段（模仿真实文件）。
/// 传 nil 的字段不写入。
func claudeConfig(uuid: String?, email: String?, orgName: String? = nil,
                  orgType: String? = nil, rateLimitTier: String? = nil) -> [String: Any] {
    var account: [String: Any] = ["seatTier": NSNull(), "userRateLimitTier": NSNull()]
    if let uuid { account["accountUuid"] = uuid }
    if let email { account["emailAddress"] = email }
    if let orgName { account["organizationName"] = orgName }
    if let orgType { account["organizationType"] = orgType }
    if let rateLimitTier { account["organizationRateLimitTier"] = rateLimitTier }
    return ["oauthAccount": account, "mcpServers": [String: Any](), "projects": [String: Any](),
            "hasCompletedOnboarding": true]
}
