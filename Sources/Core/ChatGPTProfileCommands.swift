// App 里添加 ChatGPT 档案（chatgpt-profiles ticket 05）。与 Claude 一侧（ProfileCommands）一样，App 自己不建档案：
// 打开终端执行 `ccp chatgpt add <名字>`（见 TerminalLauncher），由 ccp 布置共享资源并运行 codex login（ADR 0006）。
// 这里只做 App 这一侧需要的事：提交前检查档案名、拼出要执行的命令、判断进行中的添加是否完成。
// 删除（ticket 06）同样打开终端执行 `ccp chatgpt rm <名字>`（确认、停止守护进程、codex logout 都在 ccp 里），
// 这里判断删除入口是否可用（默认档案、当前档案、launchd 仍指向的档案不可用，与 ccp chatgpt rm 相同）。
// 守护进程只在 ccp 里查找和停止（确认之后），App 不查。

import Foundation

struct ChatGPTProfileCommands {
    private let environment: CoreEnvironment
    private let claude: ProfileCommands
    private var paths: ChatGPTProfilePaths { ChatGPTProfilePaths(environment: environment) }

    /// bundledCcp：App 内置的 ccp（Contents/Resources/shell/bin/ccp）；没有安装 ~/.cc-pilot 时用它
    init(environment: CoreEnvironment = .live, bundledCcp: URL?) {
        self.environment = environment
        claude = ProfileCommands(environment: environment, bundledCcp: bundledCcp)
    }

    /// 新 ChatGPT 档案名有什么问题（规则与 ccp chatgpt add 相同）；可以新建时返回 nil。
    /// 只看 ~/.codex-profiles/：两个工具可以有同名档案。
    func newNameProblem(_ name: String) -> ProfileCommands.NewNameProblem? {
        if name.isEmpty { return .empty }
        if !ProfileName.isWellFormed(name) { return .malformed }
        if ProfileName.reserved.contains(name) { return .reserved }
        // 与 ccp chatgpt add 的 [[ -e $dir || -L $dir ]] 一致：任何类型的同名项都算，悬空的软链接也算
        if (try? FileManager.default.attributesOfItem(atPath: paths.codexHome(for: name))) != nil {
            return .exists
        }
        return nil
    }

    /// 新建 ChatGPT 档案：在终端里执行的一行命令（ccp chatgpt add 会创建档案并在其中运行 codex login）
    func addCommand(_ name: String) -> String { claude.ccpCommand(["chatgpt", "add", name]) }

    /// 删除 ChatGPT 档案：在终端里执行的一行命令（ccp chatgpt rm 会确认、停止守护进程、codex logout，
    /// 确认 auth.json 已不在才删除）
    func removeCommand(_ name: String) -> String { claude.ccpCommand(["chatgpt", "rm", name]) }

    /// 删除入口是否可用，规则与 ccp chatgpt rm 相同；可以删除时返回 nil。
    /// currentProfile：ChatGPT 当前档案名（ChatGPTProfileStore.currentProfileName()）。记录里的名字可能只与目录名
    /// 差在大小写，所以指向同一个目录也算当前档案。
    /// launchdCodexHome：launchd 里的 CODEX_HOME（LaunchdEnvironment.codexHome()，读不到时为 nil）；等于档案目录
    /// （允许结尾多一个 /）或是同一个目录时不能删除——之后从 Dock 等打开的 ChatGPT 还会用它。
    func removalBlocker(profile: String, currentProfile: String,
                        launchdCodexHome: String?) -> ProfileCommands.RemovalBlocker? {
        if profile == ProfileName.defaultName { return .defaultProfile }
        let dir = paths.codexHome(for: profile)
        if profile == currentProfile { return .currentProfile }
        if currentProfile != ProfileName.defaultName, ProfileName.isProfileName(currentProfile),
           Self.sameDirectory(paths.codexHome(for: currentProfile), dir) {
            return .currentProfile
        }
        if let home = launchdCodexHome, !home.isEmpty {
            let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
            if trimmed == dir || Self.sameDirectory(home, dir) { return .launchdProfile }
        }
        return nil
    }

    /// 两个路径是否是同一个目录（跟随软链接，比较设备号和 inode，与 shell 的 [[ a -ef b ]] 一致）；任一个不存在时为 false
    private static func sameDirectory(_ a: String, _ b: String) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a, &sa) == 0, stat(b, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }
}

extension ProfileCommands.PendingChange {
    /// ChatGPT 档案的添加或删除是否已完成。添加：新档案出现且不再是未登录（auth.json 已写入，
    /// ChatGPT 登录或 API key 都算）。删除：档案从列表中消失。
    func isFinished(inChatGPT profiles: [ChatGPTProfile]) -> Bool {
        let profile = profiles.first { $0.name == profileName }
        switch self {
        case .adding: return profile.map { $0.status != .notLoggedIn } ?? false
        case .removing: return profile == nil
        }
    }
}
