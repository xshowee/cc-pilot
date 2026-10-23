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

    /// ~/.claude-profiles/ 下有没有名字与 name 逐字节相同的目录（跟随软链接，与 shell 的
    /// _ccp_profile_exists 一致）。macOS 的文件系统默认不分大小写，只看路径是否存在时 Work 也能
    /// 找到 work 目录，但 CLAUDE_CONFIG_DIR 会是 .../Work，钥匙串 service 名随之不同；所以按目录名比较。
    /// 不检查名字规则。
    func profileDirectoryExists(_ name: String) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: profilesRootPath),
              entries.contains(where: { $0.utf8.elementsEqual(name.utf8) })
        else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: configDir(for: name), isDirectory: &isDir) && isDir.boolValue
    }

    /// 两个档案名是否指向同一个目录（跟随软链接，比较设备号和 inode，与 shell 的 [[ a -ef b ]] 一致）。
    /// 任一个不存在时为 false。
    func sameProfileDirectory(_ a: String, _ b: String) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(configDir(for: a), &sa) == 0, stat(configDir(for: b), &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }
}
