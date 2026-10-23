// 检查用的临时主目录。每个检查新建一个，结束时 `remove()`（一般写在 defer 里）。
// 路径里故意带空格，和 tests/shell/lib.zsh 的 $T_HOME 一样。

import Foundation

final class TempHome {
    /// 临时根目录（其下的 `home dir` 是主目录）
    let root: URL
    /// 作为 HOME 交给 App 核心的目录
    let url: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-pilot-check-\(UUID().uuidString)")
        url = root.appendingPathComponent("home dir")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    var environment: CoreEnvironment { CoreEnvironment(home: url) }

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
