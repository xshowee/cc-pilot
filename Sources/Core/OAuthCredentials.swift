// 钥匙串里存的 Claude Code 凭据（顶层 claudeAiOauth）。只取 spec 列出的字段，其余一律忽略。
//
// 含有令牌，所以：
// - 只在判定登录状态、或单次额度请求期间存在于内存里，从不缓存、写盘或记入日志；
// - description / debugDescription / Mirror 都不显示令牌，误把它插进字符串、错误信息或 dump 也不会泄露。

import Foundation

struct OAuthCredentials {
    let accessToken: String?
    /// 短期凭据的过期时间（钥匙串里是毫秒时间戳）
    let expiresAt: Date?
    let refreshToken: String?
    /// 长期凭据的过期时间（毫秒时间戳；没有这个字段表示不知道，按未过期处理）
    let refreshTokenExpiresAt: Date?
    let scopes: [String]?
    /// 订阅类型（Claude Code 写入的取值如 pro、max、team、enterprise；未在真实账号上逐一核实）
    let subscriptionType: String?
    /// 限速等级（如 default_claude_max_20x），只用来补上 Max 的倍数
    let rateLimitTier: String?

    /// 解析钥匙串内容；不是 JSON 对象、或没有 claudeAiOauth 对象时返回 nil。
    /// 字段类型不对时当作缺失。
    init?(json data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
        accessToken = Self.string(oauth["accessToken"])
        expiresAt = Self.millisecondsDate(oauth["expiresAt"])
        refreshToken = Self.string(oauth["refreshToken"])
        refreshTokenExpiresAt = Self.millisecondsDate(oauth["refreshTokenExpiresAt"])
        scopes = (oauth["scopes"] as? [Any])?.compactMap { $0 as? String }
        subscriptionType = Self.string(oauth["subscriptionType"])
        rateLimitTier = Self.string(oauth["rateLimitTier"])
    }

    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }

    /// 数字（毫秒）→ Date；布尔值、字符串等其他类型当作缺失
    private static func millisecondsDate(_ value: Any?) -> Date? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return Date(timeIntervalSince1970: n.doubleValue / 1000)
    }
}

extension OAuthCredentials: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "OAuthCredentials(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// 发一次额度请求所需的凭据。只有登录状态为"可以请求额度"时才拿得到（见 LoginChecker）。
/// 用完即丢，不要保存。
struct UsageCredential {
    let accessToken: String
}

extension UsageCredential: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "UsageCredential(<redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
