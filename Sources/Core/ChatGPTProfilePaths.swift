// ChatGPT 档案的磁盘约定（ADR 0005，与 shell/lib/chatgpt-profiles.zsh 一致）：
//   默认档案              $HOME/.codex（不设置 CODEX_HOME）
//   档案根目录            $HOME/.codex-profiles
//   其他档案              $HOME/.codex-profiles/<名字>/，即它的 CODEX_HOME
//   当前档案记录          $HOME/.codex-profiles/active（格式同 Claude 一侧）
//   登录凭据              <档案目录>/auth.json
// 档案名规则与 Claude 一侧相同（ProfileName）。

import Foundation

struct ChatGPTProfilePaths {
    private let claude: ProfilePaths

    init(environment: CoreEnvironment) {
        claude = ProfilePaths(environment: environment)
    }

    /// HOME 的字符串形式，去掉结尾的 /
    var homePath: String { claude.homePath }

    var defaultDirectoryPath: String { homePath + "/.codex" }
    var profilesRootPath: String { homePath + "/.codex-profiles" }
    var activeRecord: URL { URL(fileURLWithPath: profilesRootPath + "/" + ProfileName.activeRecordName) }

    /// 非默认档案的 CODEX_HOME
    func codexHome(for name: String) -> String { profilesRootPath + "/" + name }

    /// 档案目录：默认档案是 ~/.codex，其他档案是它的 CODEX_HOME
    func directory(forProfileNamed name: String) -> String {
        name == ProfileName.defaultName ? defaultDirectoryPath : codexHome(for: name)
    }

    func authJSON(forProfileNamed name: String) -> URL {
        URL(fileURLWithPath: directory(forProfileNamed: name) + "/auth.json")
    }

    /// ~/.codex 是不是目录（跟随软链接）：不是时 ChatGPT 这个工具视为没有安装
    var defaultDirectoryExists: Bool { Self.isDirectory(defaultDirectoryPath) }

    /// ~/.codex-profiles/ 下的档案名：合规、不是保留名、是目录（跟随软链接），按字节序（与 ccp chatgpt ls 相同）
    func profileNames() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: profilesRootPath) else { return [] }
        return entries
            .filter { ProfileName.isProfileName($0) && Self.isDirectory(codexHome(for: $0)) }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
