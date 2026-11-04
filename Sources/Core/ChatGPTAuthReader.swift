// 只读解析 ChatGPT 档案的 auth.json（spec "登录状态"）：
//   {"auth_mode":"chatgpt"|"apikey", "OPENAI_API_KEY":…, "tokens":{"id_token","access_token","refresh_token","account_id"}, …}
// - 没有 auth.json → 未登录
// - auth_mode 为 apikey → API key（不读令牌）
// - auth_mode 为 chatgpt，或没有 auth_mode 但有 tokens（早期版本）→ 解析令牌：
//     id_token 载荷：email、https://api.openai.com/auth 的 chatgpt_plan_type、chatgpt_user_id
//     tokens.account_id：工作区 ID（没有时用载荷里的 chatgpt_account_id；两者都没有 → 版本不兼容）
//     access_token 的 exp（秒）≤ 现在 → 待续期；没有 exp 按未过期（同 Claude 一侧）
// - 其他（打不开、不是 JSON、缺 tokens、令牌不是 JWT、auth_mode 是不认识的值）→ 版本不兼容
//   （不认识的 auth_mode 不当作 API key：宁可提示更新 cc-pilot，也不给出可能错误的说法）
// 令牌只在内存里用于解析；返回值里只有 Reading.accessToken 带令牌，且只给 usageAuthorization 用。
// 从不写入、续期 auth.json。

import Foundation

enum ChatGPTAuthReader {
    struct Reading {
        let status: ChatGPTLoginStatus
        let account: ChatGPTAccount?
        /// 只在 status 为可以请求额度时有值
        var credential: ChatGPTUsageCredential? = nil
    }

    static let claimsKey = "https://api.openai.com/auth"

    static func read(at url: URL, now: Date) -> Reading {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Reading(status: .notLoggedIn, account: nil)
        } catch {
            return Reading(status: .incompatible(.unreadableFile), account: nil)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return malformed
        }
        let mode = root["auth_mode"] as? String
        switch mode {
        case "apikey"?: return Reading(status: .apiKey, account: nil)
        case "chatgpt"?, nil: break
        default: return malformed
        }
        if mode == nil, root["tokens"] == nil || root["tokens"] is NSNull {
            // 早期版本没有 auth_mode：只有 API key 时是 API key 登录
            return nonEmpty(root["OPENAI_API_KEY"]) == nil ? malformed : Reading(status: .apiKey, account: nil)
        }
        guard let tokens = root["tokens"] as? [String: Any],
              let idToken = nonEmpty(tokens["id_token"]), let idClaims = JWTPayload.decode(idToken),
              let accessToken = nonEmpty(tokens["access_token"]), let accessClaims = JWTPayload.decode(accessToken)
        else { return malformed }

        let auth = idClaims[claimsKey] as? [String: Any] ?? [:]
        let account = ChatGPTAccount(
            email: nonEmpty(idClaims["email"]),
            planType: nonEmpty(auth["chatgpt_plan_type"]),
            userID: nonEmpty(auth["chatgpt_user_id"]) ?? nonEmpty(auth["user_id"]),
            workspaceID: nonEmpty(tokens["account_id"]) ?? nonEmpty(auth["chatgpt_account_id"]))

        // 没有工作区 ID 就发不了额度请求（ChatGPT-Account-Id 头），也无从判断账号：按读不懂处理
        guard let workspace = account.workspaceID else { return malformed }

        if let exp = accessClaims["exp"] as? NSNumber, Date(timeIntervalSince1970: exp.doubleValue) <= now {
            return Reading(status: .needsRenewal, account: account)
        }
        return Reading(status: .canRequestUsage, account: account,
                       credential: ChatGPTUsageCredential(accessToken: accessToken, accountID: workspace))
    }

    private static var malformed: Reading { Reading(status: .incompatible(.malformed), account: nil) }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
