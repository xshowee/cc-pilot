// 面板里点击 ChatGPT 档案时的切换（chatgpt-profiles ticket 04，ADR 0005）。
// App 自己不写记录、不调 launchctl：在后台执行 ccp chatgpt use <名字>（App 核心 ChatGPTProfileSwitcher）。
// 只做切换，不弹确认框、不退出也不重新打开 ChatGPT 桌面 App：它正在运行时由用户自己退出并重新打开，
// 下次打开时使用新档案。新的当前档案由 ChatGPT 的文件监听读回（ChatGPTProfileListModel）。
//
// App 启动时（AppDelegate）调用 restoreAtLaunch()：执行 ccp chatgpt use <当前档案>，
// 恢复重启后丢失的 launchd 环境变量。

import AppKit
import Foundation

@MainActor
final class ChatGPTSwitchModel: ObservableObject {
    /// 正在后台执行 ccp chatgpt use
    @Published private(set) var isSwitching = false

    private let switcher: ChatGPTProfileSwitcher

    init(environment: CoreEnvironment = .live) {
        switcher = Self.makeSwitcher(environment: environment)
    }

    nonisolated private static func makeSwitcher(environment: CoreEnvironment) -> ChatGPTProfileSwitcher {
        let ccp = Bundle.main.resourceURL?.appendingPathComponent("shell/bin/ccp")
        let bundled = ccp.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
        return ChatGPTProfileSwitcher(environment: environment, bundledCcp: bundled)
    }

    /// 切换到 name。已是当前档案或正在切换时什么都不做。finished：ccp 结束后（无论结果）在主线程调用。
    func switchTo(_ name: String, currentName: String, finished: @escaping () -> Void = {}) {
        guard !isSwitching, name != currentName else { return }
        isSwitching = true
        let switcher = switcher
        Task {
            let result = await Task.detached { Result { try switcher.switchTo(name) } }.value
            isSwitching = false
            finished()
            if case .failure(let error) = result {
                NSLog("CC Pilot: 切换 ChatGPT 档案失败：%@", String(describing: error))
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Couldn’t switch the ChatGPT profile")
                alert.informativeText = (error as? ChatGPTProfileSwitcher.Failure)?.message ?? String(describing: error)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    /// App 启动时调用一次（在 ~/.cc-pilot 更新之后）：在后台恢复 launchd 里的 CODEX_HOME。失败只记日志。
    nonisolated static func restoreAtLaunch(environment: CoreEnvironment = .live) {
        let switcher = makeSwitcher(environment: environment)
        DispatchQueue.global(qos: .utility).async {
            do {
                try switcher.restoreAtLaunch()
            } catch {
                NSLog("CC Pilot: 恢复 ChatGPT 当前档案的 launchd 环境变量失败：%@", String(describing: error))
            }
        }
    }
}
