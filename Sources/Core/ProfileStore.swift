// 列出档案。只读：从不写入任何文件。

import Foundation

struct ProfileStore: Sendable {
    let environment: CoreEnvironment
    private var paths: ProfilePaths { ProfilePaths(environment: environment) }

    init(environment: CoreEnvironment = .live) {
        self.environment = environment
    }

    /// 默认档案在最前，其余档案按名字的字节序排列（与 ccp ls 相同）。
    func listProfiles() -> [Profile] {
        let defaultProfile = Profile(
            name: ProfileName.defaultName, configDir: nil,
            claudeJSON: paths.defaultClaudeJSON,
            account: ClaudeConfigReader.readAccount(at: paths.defaultClaudeJSON))
        let others = profileNames().map { name in
            Profile(name: name, configDir: paths.configDir(for: name),
                    claudeJSON: paths.claudeJSON(for: name),
                    account: ClaudeConfigReader.readAccount(at: paths.claudeJSON(for: name)))
        }
        return Self.markingSharedAccounts([defaultProfile] + others)
    }

    /// 按 accountUuid 找出登录同一账号的档案，填 sameAccountAs（保持列表顺序）。
    /// 没有 accountUuid 的、未登录的不参与。
    static func markingSharedAccounts(_ profiles: [Profile]) -> [Profile] {
        var namesByAccount: [String: [String]] = [:]
        for p in profiles {
            if let uuid = p.account.account?.accountUuid { namesByAccount[uuid, default: []].append(p.name) }
        }
        return profiles.map { p in
            var p = p
            if let uuid = p.account.account?.accountUuid {
                p.sameAccountAs = (namesByAccount[uuid] ?? []).filter { $0 != p.name }
            }
            return p
        }
    }

    /// ~/.claude-profiles/ 下的档案名：名字合规、不是保留名（default、active）、而且是目录
    /// （跟随软链接，与 shell 的 [[ -d ]] 一致）。当前档案记录、临时文件、隐藏文件都不算。
    private func profileNames() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: paths.profilesRootPath) else { return [] }
        return entries
            .filter { name in
                var isDir: ObjCBool = false
                return ProfileName.isProfileName(name)
                    && fm.fileExists(atPath: paths.configDir(for: name), isDirectory: &isDir)
                    && isDir.boolValue
            }
            // 按字节序，与 ccp ls（LC_COLLATE=C）的顺序相同
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
}
