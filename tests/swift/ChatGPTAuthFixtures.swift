// ChatGPT 档案检查用的夹具（chatgpt-profiles ticket 02）：构造 ~/.codex、~/.codex-profiles/<名字>/ 和 auth.json。
//
// auth.json 的形状（spec Further Notes，2026-11-04 本机实测）：
//   {"auth_mode":"chatgpt","OPENAI_API_KEY":null,
//    "tokens":{"id_token":"<JWT>","access_token":"<JWT>","refresh_token":"…","account_id":"<工作区 ID>"},
//    "last_refresh":"…"}
// id_token 载荷里有 email 和 "https://api.openai.com/auth": {chatgpt_plan_type, chatgpt_user_id, chatgpt_account_id}；
// access_token 载荷里有 exp（秒）。JWT 用真实的 header.payload.signature 形式，base64url 不补 =。

import Foundation

/// 夹具里的令牌哨兵：只要在任何输出里出现，就说明凭据泄露了
enum ChatGPTSentinel {
    static let accessSignature = "SENTINEL_CHATGPT_ACCESS_SIG_6f1e"
    static let idSignature = "SENTINEL_CHATGPT_ID_SIG_9a2c"
    static let refreshToken = "SENTINEL_CHATGPT_REFRESH_41d7"
    static let apiKey = "sk-SENTINEL_CHATGPT_APIKEY_77b0"
    static let all = [accessSignature, idSignature, refreshToken, apiKey]
}

/// base64url（不补 =）
func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// 一个 JWT：header.payload.signature。signature 原样作为第三段（哨兵只含 base64url 合法字符），
/// 所以令牌文本里能直接搜到哨兵。
func makeJWT(_ payload: [String: Any], signature: String) -> String {
    let header = try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"])
    let body = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return base64URL(header) + "." + base64URL(body) + "." + signature
}

/// ChatGPT 登录的 auth.json。传 nil 的字段不写入；accessExp 是相对 fixedNow 的秒数（nil 表示 access token 不带 exp）。
func chatgptAuth(email: String? = "me@example.com", plan: String? = "plus",
                 userID: String? = "user-me", workspaceID: String? = "ws-1",
                 accessExp: TimeInterval? = 3600, authMode: String? = "chatgpt") -> [String: Any] {
    var claims: [String: Any] = [:]
    if let plan { claims["chatgpt_plan_type"] = plan }
    if let userID { claims["chatgpt_user_id"] = userID; claims["user_id"] = userID }
    if let workspaceID { claims["chatgpt_account_id"] = workspaceID }
    var idPayload: [String: Any] = ["https://api.openai.com/auth": claims, "iss": "https://auth.openai.com",
                                    "exp": fixedNow.timeIntervalSince1970 + 3600]
    if let email { idPayload["email"] = email }
    var accessPayload: [String: Any] = ["https://api.openai.com/auth": claims, "scp": ["openid", "email"]]
    if let accessExp { accessPayload["exp"] = Int(fixedNow.timeIntervalSince1970 + accessExp) }

    var tokens: [String: Any] = [
        "id_token": makeJWT(idPayload, signature: ChatGPTSentinel.idSignature),
        "access_token": makeJWT(accessPayload, signature: ChatGPTSentinel.accessSignature),
        "refresh_token": ChatGPTSentinel.refreshToken,
    ]
    if let workspaceID { tokens["account_id"] = workspaceID }
    var auth: [String: Any] = ["OPENAI_API_KEY": NSNull(), "tokens": tokens,
                               "last_refresh": "2026-11-04T08:00:00.000000Z"]
    if let authMode { auth["auth_mode"] = authMode }
    return auth
}

/// API key 登录的 auth.json
func apiKeyAuth() -> [String: Any] {
    ["auth_mode": "apikey", "OPENAI_API_KEY": ChatGPTSentinel.apiKey]
}

extension TempHome {
    var codexProfilesRoot: URL { url.appendingPathComponent(".codex-profiles") }

    /// 创建 ChatGPT 默认档案目录 ~/.codex（auth 不为 nil 时写入它的 auth.json）
    func makeCodexDefault(auth: [String: Any]? = nil) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".codex"),
                                                withIntermediateDirectories: true)
        if let auth { try writeJSON(".codex/auth.json", auth) }
    }

    /// 创建 ChatGPT 档案目录 ~/.codex-profiles/<名字>/（auth 不为 nil 时写入它的 auth.json）
    func makeCodexProfile(_ name: String, auth: [String: Any]? = nil) throws {
        try FileManager.default.createDirectory(at: codexProfilesRoot.appendingPathComponent(name),
                                                withIntermediateDirectories: true)
        if let auth { try writeJSON(".codex-profiles/\(name)/auth.json", auth) }
    }
}
