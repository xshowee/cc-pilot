// 列出 ChatGPT 档案、读取 ChatGPT 当前档案。只读：从不写入任何文件（切换由 ccp chatgpt use 完成，ADR 0005）。

import Foundation

struct ChatGPTProfileStore: Sendable {
    let environment: CoreEnvironment
    private var paths: ChatGPTProfilePaths { ChatGPTProfilePaths(environment: environment) }

    init(environment: CoreEnvironment = .live) {
        self.environment = environment
    }

    /// 默认档案 ~/.codex 是否存在。不存在时视为没有装 ChatGPT：listProfiles 为空，面板不显示这一段。
    var defaultProfileExists: Bool { paths.defaultDirectoryExists }

    /// 默认档案在最前，其余档案按名字的字节序排列（与 ccp chatgpt ls 相同），并标出同一账号。
    /// 没有默认档案时为空（即使 ~/.codex-profiles/ 下有档案）。登录状态按 now 判定是否过期。
    func listProfiles(now: Date = Date()) -> [ChatGPTProfile] {
        guard defaultProfileExists else { return [] }
        return Self.markingSharedAccounts(allProfileNames().map { profile(named: $0, now: now) })
    }

    /// listProfiles 里的档案名（不看默认档案是否存在）
    func allProfileNames() -> [String] {
        [ProfileName.defaultName] + paths.profileNames()
    }

    /// 读一个档案（默认档案是 "default"）。不填 sameAccountAs。
    func profile(named name: String, now: Date = Date()) -> ChatGPTProfile {
        let reading = ChatGPTAuthReader.read(at: paths.authJSON(forProfileNamed: name), now: now)
        let isDefault = name == ProfileName.defaultName
        return ChatGPTProfile(name: name, codexHome: isDefault ? nil : paths.codexHome(for: name),
                              directory: paths.directory(forProfileNamed: name),
                              account: reading.account, status: reading.status)
    }

    /// ChatGPT 当前档案的名字（"default" 表示默认档案）。读法同 Claude 一侧；可能是不合规或不存在的名字，原样返回。
    func currentProfileName() -> String {
        CurrentProfileRecord.readName(at: paths.activeRecord)
    }

    /// 发额度请求之前调用：重新读取 auth.json 并判定，只有"可以请求额度"时才给出令牌和工作区 ID。
    /// 拿到的凭据只在这一次请求里用，用完即丢。
    func usageAuthorization(for profile: ChatGPTProfile, now: Date = Date()) -> ChatGPTUsageAuthorization {
        let reading = ChatGPTAuthReader.read(at: paths.authJSON(forProfileNamed: profile.name), now: now)
        guard reading.status == .canRequestUsage, let credential = reading.credential else {
            // 能请求额度却没有工作区 ID 时无法发请求，按读不懂处理
            return .denied(reading.status == .canRequestUsage ? .incompatible(.malformed) : reading.status)
        }
        return .granted(credential)
    }

    /// 按 ChatGPTAccountKey（用户 ID + 工作区 ID）标出登录同一账号的档案（保持列表顺序）。
    static func markingSharedAccounts(_ profiles: [ChatGPTProfile]) -> [ChatGPTProfile] {
        var namesByKey: [ChatGPTAccountKey: [String]] = [:]
        for p in profiles {
            if let key = p.account?.key { namesByKey[key, default: []].append(p.name) }
        }
        return profiles.map { p in
            var p = p
            if let key = p.account?.key { p.sameAccountAs = (namesByKey[key] ?? []).filter { $0 != p.name } }
            return p
        }
    }
}
