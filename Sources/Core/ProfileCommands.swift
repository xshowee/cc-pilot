// App 里添加与删除档案（ticket 09）。App 自己不实现添加和删除，全部交给 ccp：
// 在终端里执行 `ccp add <名字>` / `ccp rm <名字>`（见 TerminalLauncher），两个入口的行为始终一致。
// 这里只做 App 这一侧需要的事：提交前检查档案名、判断删除入口是否可用、拼出要执行的命令。

import Foundation

struct ProfileCommands {
    /// 新档案名的问题（规则与 ccp add 相同，提交前检查，有问题就不打开终端）
    enum NewNameProblem: Equatable {
        /// 还没输入
        case empty
        /// 不合规（只能包含字母、数字、. _ -，且以字母或数字开头）
        case malformed
        /// 保留名：default、active
        case reserved
        /// ~/.claude-profiles/ 下已有同名的项
        case exists
    }

    private let environment: CoreEnvironment
    private let bundledCcp: URL?
    private var paths: ProfilePaths { ProfilePaths(environment: environment) }

    /// bundledCcp：App 内置的 ccp（Contents/Resources/shell/bin/ccp）；没有安装 ~/.cc-pilot 时用它
    init(environment: CoreEnvironment = .live, bundledCcp: URL?) {
        self.environment = environment
        self.bundledCcp = bundledCcp
    }

    /// 新档案名有什么问题；可以用来新建档案时返回 nil
    func newNameProblem(_ name: String) -> NewNameProblem? {
        if name.isEmpty { return .empty }
        if !ProfileName.isWellFormed(name) { return .malformed }
        if ProfileName.reserved.contains(name) { return .reserved }
        // 与 ccp add 的 [[ -e $dir || -L $dir ]] 一致：任何类型的同名项都算，悬空的软链接也算
        if (try? FileManager.default.attributesOfItem(atPath: paths.configDir(for: name))) != nil {
            return .exists
        }
        return nil
    }

    /// 不能删除某个档案的原因（与 ccp rm 的规则相同）
    enum RemovalBlocker: Equatable {
        case defaultProfile
        case currentProfile
    }

    /// 删除入口是否可用：默认档案和当前档案不能删除，返回原因；可以删除时返回 nil。
    /// currentProfile：当前档案名（CurrentProfileRecord.currentName()）
    static func removalBlocker(profile: String, currentProfile: String) -> RemovalBlocker? {
        if profile == ProfileName.defaultName { return .defaultProfile }
        if profile == currentProfile { return .currentProfile }
        return nil
    }

    /// 已在终端里开始、还没完成的添加或删除。App 不知道终端里发生了什么，只看档案列表：
    /// 列表由 ProfileWatcher 在文件变化时重读，这里据此判断是否已经完成。
    enum PendingChange: Equatable {
        case adding(String)
        case removing(String)

        var profileName: String {
            switch self {
            case .adding(let name), .removing(let name): return name
            }
        }

        /// 添加：新档案出现且 .claude.json 里有了账号资料（已登录）。删除：档案从列表中消失。
        /// ccp rm 拒绝删除时档案一直在列表里，删除就一直不算完成。
        func isFinished(in profiles: [Profile]) -> Bool {
            let profile = profiles.first { $0.name == profileName }
            switch self {
            case .adding: return profile?.account.account != nil
            case .removing: return profile == nil
            }
        }
    }

    // MARK: 交给终端执行的命令

    /// 新建档案：在终端里执行的一行命令（ccp add 会创建档案并进入它的 Claude Code 登录）
    func addCommand(_ name: String) -> String { ccpCommand(["add", name]) }

    /// 删除档案：在终端里执行的一行命令（ccp rm 会确认、引导登出，确认已登出才删除）
    func removeCommand(_ name: String) -> String { ccpCommand(["rm", name]) }

    /// 一行 shell 命令（用户在终端里看到的、也是给用户复制的就是它）。
    /// 已安装 ~/.cc-pilot 时用 `~/.cc-pilot/bin/ccp`（简短，zsh、bash、fish 都会展开 ~）；
    /// 否则用 App 内置的 ccp 的绝对路径。不依赖终端里的 PATH 里有没有 ccp。
    private func ccpCommand(_ arguments: [String]) -> String {
        let installed = paths.homePath + "/.cc-pilot/bin/ccp"
        let ccp: String
        if FileManager.default.isExecutableFile(atPath: installed) || bundledCcp == nil {
            ccp = "~/.cc-pilot/bin/ccp"
        } else {
            ccp = Self.shellQuote(bundledCcp!.path)
        }
        return ([ccp] + arguments.map(Self.shellQuote)).joined(separator: " ")
    }

    /// 只含安全字符时原样输出，否则用单引号括起来（POSIX shell、zsh、bash 都适用）
    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/+=:@%,")
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
