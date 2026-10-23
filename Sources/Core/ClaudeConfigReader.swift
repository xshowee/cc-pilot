// 读取 Claude Code 的 .claude.json，只取 oauthAccount 里的账号资料。
// 真实文件有上百个顶层键，这里一律不建模；所有字段都容忍缺失、为 null 或类型不对。

import Foundation

enum ClaudeConfigReader {
    /// 读取一个 .claude.json 的账号状态。
    /// - 文件不存在：未登录（例如刚建好、还没启动过 Claude Code 的档案）
    /// - 文件读不了、不是 JSON、顶层不是对象、oauthAccount 不是对象：.unreadable
    /// - 没有 oauthAccount、为 null，或其中既没有 accountUuid 也没有 emailAddress：未登录
    static func readAccount(at url: URL) -> AccountState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .loggedOut
        } catch {
            return .unreadable(.unreadableFile)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unreadable(.malformed)
        }
        return accountState(fromConfig: root)
    }

    static func accountState(fromConfig root: [String: Any]) -> AccountState {
        guard let raw = root["oauthAccount"], !(raw is NSNull) else { return .loggedOut }
        guard let oauth = raw as? [String: Any] else { return .unreadable(.malformed) }

        let uuid = nonEmptyString(oauth["accountUuid"])
        let email = nonEmptyString(oauth["emailAddress"])
        guard uuid != nil || email != nil else { return .loggedOut }

        return .loggedIn(Account(
            accountUuid: uuid,
            email: email,
            organizationName: nonEmptyString(oauth["organizationName"]),
            tier: SubscriptionTier.infer(
                organizationType: nonEmptyString(oauth["organizationType"]),
                rateLimitTier: nonEmptyString(oauth["organizationRateLimitTier"]))))
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
