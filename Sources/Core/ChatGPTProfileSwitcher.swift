// App 切换 ChatGPT 档案（chatgpt-profiles ticket 04，ADR 0005）。
//
// 切换逻辑只在 shell 里实现一份（shell/lib/cmd-chatgpt-use.zsh）：App 不自己写当前档案记录、不调 launchctl，
// 而是在后台（不打开终端）执行 `ccp chatgpt use <名字>`；App 启动时执行一次 `ccp chatgpt use <当前档案>`，
// 恢复重启或注销后丢失的 launchd 环境变量。之后的当前档案由文件监听读回（ChatGPTProfileStore）。
// 只做切换：不退出、不重新打开 ChatGPT 桌面 App，它正在运行时由用户自己重启。
//
// 执行哪个 ccp：已安装 ~/.cc-pilot/bin/ccp 时用它，否则用 App 内置的（与 ShellIntegration.disconnect 相同）。
// 环境只有 HOME、PATH（CoreEnvironment.searchPath，测试在最前面放假程序）、LANG；标准输入为空。
// 这里的方法都会等 ccp 结束，不要在主线程调用。

import Foundation

struct ChatGPTProfileSwitcher {
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

    /// 交给 ccp 的参数
    static func arguments(switchingTo name: String) -> [String] {
        ["chatgpt", "use", name]
    }

    /// 切换到 name。
    func switchTo(_ name: String) throws {
        try runCcp(Self.arguments(switchingTo: name))
    }

    /// App 启动时调用：按当前 ChatGPT 档案执行一次 ccp chatgpt use。没用过 ChatGPT 档案
    /// （~/.codex-profiles 不存在，cc-pilot 从没设置过 launchd 的 CODEX_HOME）时什么都不做，返回 false。
    @discardableResult
    func restoreAtLaunch() throws -> Bool {
        let paths = ChatGPTProfilePaths(environment: environment)
        guard ChatGPTProfilePaths.isDirectory(paths.profilesRootPath) else { return false }
        let current = ChatGPTProfileStore(environment: environment).currentProfileName()
        try runCcp(Self.arguments(switchingTo: current))
        return true
    }

    private func runCcp(_ arguments: [String]) throws {
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
        guard result.status == 0 else {
            throw Failure(status: result.status, message: result.stderr)
        }
    }
}
