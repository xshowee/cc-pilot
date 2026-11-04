// 面板里点击 ChatGPT 档案时的切换（chatgpt-profiles ticket 04，ADR 0005）。
// App 自己不写记录、不调 launchctl、不退出桌面 App：ChatGPT 桌面 App 正在运行时先弹确认框
// "需要重启 ChatGPT，正在进行的任务会中断"，然后在后台执行 ccp chatgpt use <名字> --restart|--no-restart
// （App 核心 ChatGPTProfileSwitcher）；用户选"以后再说"时档案照样切换，桌面 App 下次打开时生效。
// 新的当前档案由 ChatGPT 的文件监听读回（ChatGPTProfileListModel）。
//
// 退出桌面 App 由 ccp 里的 osascript 发 Apple 事件，macOS 会问"CC Pilot 想要控制 ChatGPT"。被拒绝（或没能
// 重启）时档案照样已经切换，这里给出说明和可以复制到终端执行的命令（同打开终端被拒时的做法）。
//
// App 启动时（AppDelegate）调用 restoreAtLaunch()：执行 ccp chatgpt use <当前档案> --no-restart，
// 恢复重启后丢失的 launchd 环境变量。

import AppKit
import Foundation

@MainActor
final class ChatGPTSwitchModel: ObservableObject {
    /// 正在后台执行 ccp chatgpt use（可能在等桌面 App 退出）
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
        var restart = false
        if Self.desktopAppIsRunning {
            guard let choice = askToRestart(name) else { return }
            restart = choice
        }
        isSwitching = true
        let switcher = switcher
        Task {
            let result = await Task.detached { Result { try switcher.switchTo(name, restart: restart) } }.value
            isSwitching = false
            finished()
            switch result {
            case .success(.switched):
                break
            case .success(.switchedWithoutRestart(let message)):
                showNotRestarted(name, detail: message)
            case .failure(let error):
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

    private static var desktopAppIsRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: ChatGPTProfileSwitcher.desktopAppBundleID).isEmpty
    }

    /// 桌面 App 正在运行：问要不要现在重启。返回 true 重启、false 以后再说（档案照样切换）、nil 取消切换。
    private func askToRestart(_ name: String) -> Bool? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart ChatGPT?")
        alert.informativeText = String(localized: """
            ChatGPT needs to restart to use the profile “\(name)”. Tasks in progress will be interrupted.

            If you choose Later, the profile is switched now and ChatGPT uses it the next time it opens.
            """)
        alert.addButton(withTitle: String(localized: "Restart ChatGPT"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertSecondButtonReturn: return false
        default: return nil
        }
    }

    /// 档案已切换，但没能重启桌面 App：说明怎么手动完成，给出可以复制到终端执行的命令
    private func showNotRestarted(_ name: String, detail: String) {
        let command = switcher.manualRestartCommand(name)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "ChatGPT wasn’t restarted")
        alert.informativeText = String(localized: """
            The profile was switched to “\(name)”, but CC Pilot couldn’t restart ChatGPT. \
            Quit ChatGPT and open it again yourself, or copy the command below and run it in a terminal.

            To let CC Pilot restart ChatGPT for you, turn on ChatGPT under CC Pilot in \
            System Settings > Privacy & Security > Automation.
            """) + "\n\n" + detail
        alert.accessoryView = CommandTextView.make(command)
        alert.addButton(withTitle: String(localized: "Copy Command"))
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Close"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        case .alertSecondButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }
}
