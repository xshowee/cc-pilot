// App 切换 ChatGPT 档案（chatgpt-profiles ticket 04，ADR 0005）。
//
// 切换逻辑只在 shell 里实现一份（shell/lib/cmd-chatgpt-use.zsh）：App 不自己写当前档案记录、不调 launchctl、
// 不退出桌面 App，而是在后台（不打开终端）执行 `ccp chatgpt use <名字> --restart|--no-restart`；
// App 启动时执行一次 `ccp chatgpt use <当前档案> --no-restart`，恢复重启或注销后丢失的 launchd 环境变量。
// 之后的当前档案由文件监听读回（ChatGPTProfileStore）。
//
// 是否重启了只看 ccp 的退出码：切换时带上只给 App 用的 --restart-status，要求重启却没能重启时 ccp 以 3 结束
// （说明写在 stderr）；不看 stderr 是否为空（别的程序的警告也可能写到那里）。
//
// 执行哪个 ccp：已安装 ~/.cc-pilot/bin/ccp 时用它，否则用 App 内置的（与 ShellIntegration.disconnect 相同）。
// 环境只有 HOME、PATH（CoreEnvironment.searchPath，测试在最前面放假程序）、LANG；标准输入为空，
// 所以 ccp 不会停在询问上（App 总是传 --restart 或 --no-restart）。
// 这里的方法都会等 ccp 结束（重启桌面 App 时可能要等十几秒），不要在主线程调用。

import Foundation

struct ChatGPTProfileSwitcher {
    /// ChatGPT 桌面 App 的 bundle ID（ccp 也用它控制桌面 App）
    static let desktopAppBundleID = "com.openai.codex"

    enum Outcome: Equatable {
        /// 已切换（要求重启时，桌面 App 已重新打开，或者它本来就没在运行）
        case switched
        /// 已切换，但没能重启桌面 App（退出被 macOS 自动化授权拒绝、没在规定时间内退出、重新打开失败）。
        /// message 是 ccp 的说明（怎么手动完成）
        case switchedWithoutRestart(String)
    }

    /// ccp 没有切换（档案不存在、名字不合规、launchctl 失败等），或者没法执行 ccp
    struct Failure: Error, CustomStringConvertible {
        let status: Int32
        let message: String
        var description: String { "ccp chatgpt use 失败（退出码 \(status)）：\(message)" }
    }

    private let environment: CoreEnvironment
    private let bundledCcp: URL?

    /// bundledCcp：App 内置的 ccp（Contents/Resources/shell/bin/ccp）；没有安装 ~/.cc-pilot 时用它
    init(environment: CoreEnvironment = .live, bundledCcp: URL?) {
        self.environment = environment
        self.bundledCcp = bundledCcp
    }

    /// 交给 ccp 的参数（也用于给用户复制的手动命令，所以不含只给 App 用的选项）
    static func arguments(switchingTo name: String, restart: Bool) -> [String] {
        ["chatgpt", "use", name, restart ? "--restart" : "--no-restart"]
    }

    /// 只给 App 用的选项：要求重启却没能重启时，ccp 以 notRestartedStatus 结束（终端里不带它时仍是 0）
    static let restartStatusOption = "--restart-status"
    static let notRestartedStatus: Int32 = 3

    /// 切换到 name。restart：桌面 App 正在运行时是否退出并重新打开它（用户在确认框里的选择）。
    func switchTo(_ name: String, restart: Bool) throws -> Outcome {
        let result = try runCcp(Self.arguments(switchingTo: name, restart: restart) + [Self.restartStatusOption],
                                accepting: [Self.notRestartedStatus])
        // 退出码 3：档案已经切换，但没能重启桌面 App，stderr 里是 ccp 的说明
        if result.status == Self.notRestartedStatus { return .switchedWithoutRestart(result.stderr) }
        return .switched
    }

    /// App 启动时调用：按当前 ChatGPT 档案执行一次 --no-restart。没用过 ChatGPT 档案
    /// （~/.codex-profiles 不存在，cc-pilot 从没设置过 launchd 的 CODEX_HOME）时什么都不做，返回 false。
    @discardableResult
    func restoreAtLaunch() throws -> Bool {
        let paths = ChatGPTProfilePaths(environment: environment)
        guard ChatGPTProfilePaths.isDirectory(paths.profilesRootPath) else { return false }
        let current = ChatGPTProfileStore(environment: environment).currentProfileName()
        _ = try runCcp(Self.arguments(switchingTo: current, restart: false))
        return true
    }

    /// 没能重启桌面 App 时给用户复制到终端执行的命令（终端里执行时，自动化授权问的是终端，不是 CC Pilot）
    func manualRestartCommand(_ name: String) -> String {
        ProfileCommands(environment: environment, bundledCcp: bundledCcp)
            .ccpCommand(Self.arguments(switchingTo: name, restart: true))
    }

    /// accepting：除 0 以外也算 ccp 执行成功的退出码
    private func runCcp(_ arguments: [String], accepting: Set<Int32> = []) throws -> Subprocess.Result {
        let installed = environment.home.appendingPathComponent(".cc-pilot/bin/ccp")
        let ccp: URL
        if FileManager.default.isExecutableFile(atPath: installed.path) {
            ccp = installed
        } else if let bundledCcp {
            ccp = bundledCcp
        } else {
            throw Failure(status: -1, message: "找不到 ccp（没有安装 ~/.cc-pilot，App 里也没有内置的 shell/）")
        }
        let result = try Subprocess.run(ccp, arguments, environment: [
            "HOME": environment.home.path,
            "PATH": environment.searchPath,
            "LANG": "en_US.UTF-8",
        ], currentDirectory: environment.home)
        guard result.status == 0 || accepting.contains(result.status) else {
            throw Failure(status: result.status, message: result.stderr)
        }
        return result
    }
}
