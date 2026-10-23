// 磁盘上的文件约定（spec "磁盘上的文件约定"，与 shell/lib/profiles.zsh 一致）：
//   默认档案的 .claude.json   $HOME/.claude.json（不是 ~/.claude/.claude.json）
//   档案根目录               $HOME/.claude-profiles
//   其他档案                 $HOME/.claude-profiles/<名字>/，.claude.json 在其中
//   当前档案记录             $HOME/.claude-profiles/active

import Foundation

struct ProfilePaths {
    let home: URL

    init(environment: CoreEnvironment) {
        home = environment.home
    }

    /// HOME 的字符串形式，去掉结尾的 /（与 shell 的 ${HOME%%/##} 一致）
    var homePath: String {
        var path = home.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    var defaultClaudeJSON: URL { URL(fileURLWithPath: homePath + "/.claude.json") }
    var profilesRoot: URL { URL(fileURLWithPath: profilesRootPath, isDirectory: true) }
    var profilesRootPath: String { homePath + "/.claude-profiles" }
    var activeRecord: URL { URL(fileURLWithPath: profilesRootPath + "/" + ProfileName.activeRecordName) }

    /// 非默认档案的配置目录字符串（即 CLAUDE_CONFIG_DIR 的值）
    func configDir(for name: String) -> String { profilesRootPath + "/" + name }

    func claudeJSON(for name: String) -> URL {
        URL(fileURLWithPath: configDir(for: name) + "/.claude.json")
    }
}
