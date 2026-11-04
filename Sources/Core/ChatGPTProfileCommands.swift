// App 里添加 ChatGPT 档案（chatgpt-profiles ticket 05）。与 Claude 一侧（ProfileCommands）一样，App 自己不建档案：
// 打开终端执行 `ccp chatgpt add <名字>`（见 TerminalLauncher），由 ccp 布置共享资源并运行 codex login（ADR 0006）。
// 这里只做 App 这一侧需要的事：提交前检查档案名、拼出要执行的命令、判断进行中的添加是否完成。
// 删除（ticket 06）也加在这里。

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
