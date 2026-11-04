// 读取 launchd 的环境变量（chatgpt-profiles ticket 06）。App 只读不写：写入（launchctl setenv / unsetenv）只在
// ccp chatgpt use 里做一份（ADR 0005）。这里只用来判断 ChatGPT 档案的删除入口是否可用：launchd 里的 CODEX_HOME
// 仍指向某个档案时，之后从 Dock、Spotlight 打开的 ChatGPT 等还会用它，不能删除（与 ccp chatgpt rm 相同）。
// launchctl 从 CoreEnvironment 取，测试换成假的。阻塞调用线程，不要在主线程调用。

import Foundation

struct LaunchdEnvironment {
    private let environment: CoreEnvironment

    init(environment: CoreEnvironment = .live) {
        self.environment = environment
    }

    /// launchd 里的 CODEX_HOME（`launchctl getenv CODEX_HOME`）；未设置、为空或读取失败时为 nil。
    /// 读取失败时 App 不据此禁用删除入口：ccp chatgpt rm 自己会再查一次，查不到就拒绝并说明原因。
    func codexHome() -> String? { value(of: "CODEX_HOME") }

    /// launchd 里某个变量的值（去掉 launchctl 输出结尾的换行）；未设置、为空或读取失败时为 nil
    func value(of name: String) -> String? {
        let process = Process()
        process.executableURL = environment.launchctl
        process.arguments = ["getenv", name]
        process.environment = ["PATH": environment.searchPath, "HOME": environment.home.path]
        let out = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return text.isEmpty ? nil : text
    }
}
