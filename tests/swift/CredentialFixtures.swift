// ticket 10 检查共用的凭据测试数据。令牌都是一眼能认出的哨兵字符串，泄露检查就搜索它们。

import Foundation

enum Sentinel {
    static let accessToken = "sk-ant-oat01-SENTINEL-ACCESS-7f3a9c"
    static let refreshToken = "sk-ant-ort01-SENTINEL-REFRESH-2b8e4d"
    static var all: [String] { [accessToken, refreshToken] }
}

/// 固定的"现在"，所有过期判断都相对于它
let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

/// 相对 fixedNow 的毫秒时间戳
func ms(_ secondsFromNow: TimeInterval) -> Double {
    (fixedNow.timeIntervalSince1970 + secondsFromNow) * 1000
}

let fullScopes = ["user:inference", "user:profile", "user:sessions:claude_code"]

/// 构造钥匙串里存的凭据 JSON（与 Claude Code 写入的结构相同：顶层 claudeAiOauth）。
/// 传 nil 的字段不写入；extra 里的键值直接并入 claudeAiOauth。
func credentialJSON(access: String? = Sentinel.accessToken, expiresAt: Double? = ms(3600),
                    refresh: String? = Sentinel.refreshToken, refreshExpiresAt: Double? = nil,
                    scopes: [String]? = fullScopes, subscriptionType: String? = "max",
                    extra: [String: Any] = [:]) -> String {
    var oauth: [String: Any] = extra
    if let access { oauth["accessToken"] = access }
    if let expiresAt { oauth["expiresAt"] = expiresAt }
    if let refresh { oauth["refreshToken"] = refresh }
    if let refreshExpiresAt { oauth["refreshTokenExpiresAt"] = refreshExpiresAt }
    if let scopes { oauth["scopes"] = scopes }
    if let subscriptionType { oauth["subscriptionType"] = subscriptionType }
    let data = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

/// 真的 security 在内容含非 ASCII 字节时，-w 输出的是小写十六进制
func hexEncoded(_ text: String, uppercase: Bool = false) -> String {
    Data(text.utf8).map { String(format: uppercase ? "%02X" : "%02x", $0) }.joined()
}

extension TempHome {
    /// 创建一个已登录的档案（.claude.json 有账号资料），返回它的 service 名
    @discardableResult
    func makeLoggedInProfile(_ name: String, uuid: String = "uuid-1", orgType: String? = nil,
                             rateLimitTier: String? = nil) throws -> String {
        let config = claudeConfig(uuid: uuid, email: "\(name)@example.com", orgType: orgType,
                                  rateLimitTier: rateLimitTier)
        if name == "default" {
            try writeDefaultConfig(config)
            return "Claude Code-credentials"
        }
        try makeProfile(name, config: config)
        return KeychainServiceName.forConfigDir(url.path + "/.claude-profiles/" + name)
    }

    /// 列出档案并判定登录状态（固定的"现在"），返回 名字 → 档案
    func profilesWithLogin(_ environment: CoreEnvironment? = nil) -> [String: Profile] {
        let env = environment ?? self.environment
        let list = LoginChecker(environment: env)
            .withLoginStates(ProfileStore(environment: env).listProfiles(), now: fixedNow)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }

    func loginStatus(_ name: String, _ environment: CoreEnvironment? = nil) -> LoginStatus? {
        profilesWithLogin(environment)[name]?.login?.status
    }

    /// 写一个可执行脚本（放在临时根目录下，不在主目录里），返回路径
    func script(_ name: String, _ body: String) throws -> URL {
        let file = root.appendingPathComponent("bin/\(name)")
        try Data(("#!/bin/zsh -f\n" + body + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }
}
