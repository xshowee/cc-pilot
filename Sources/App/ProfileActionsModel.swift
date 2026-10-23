// 面板里添加与删除档案（ticket 09）。App 自己不实现添加和删除：打开"终端"执行 ccp add / ccp rm，
// 档案列表由 ProfileWatcher 跟着文件变化自动更新（新档案登录后显示邮箱，删除后消失）。
// 检查档案名、删除入口是否可用、拼命令在 App 核心 ProfileCommands；打开终端在 TerminalLauncher。
//
// 打开终端要用 Apple 事件控制"终端"，macOS 会请求自动化授权：
// - 系统即将弹窗询问（或者查不到状态、又从没说明过）时，先说明为什么需要、会执行什么命令；
// - 用户拒绝过授权、或打开失败时，给出可以复制到终端手动执行的命令，以及去哪里重新允许。

import AppKit
import CoreServices
import Foundation

@MainActor
final class ProfileActionsModel: ObservableObject {
    /// UserDefaults 键：是否已经说明过自动化授权
    static let explainedKey = "terminalAutomationExplained"

    /// 已在终端里开始、还没完成的添加或删除；完成后（见 update(with:)）自动清除
    @Published private(set) var pending: ProfileCommands.PendingChange?
    /// 正在打开终端（查询授权、等待系统弹窗或 Terminal 启动）
    @Published private(set) var isOpening = false

    private let commands: ProfileCommands
    private let launcher: TerminalLauncher

    init(environment: CoreEnvironment = .live) {
        let ccp = Bundle.main.resourceURL?.appendingPathComponent("shell/bin/ccp")
        let bundled = ccp.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil }
        commands = ProfileCommands(environment: environment, bundledCcp: bundled)
        launcher = TerminalLauncher(environment: environment)
    }

    /// 新档案名的问题（空、不合规、保留名、已存在）；没有问题时为 nil
    func problem(forNewName name: String) -> ProfileCommands.NewNameProblem? {
        commands.newNameProblem(name)
    }

    /// 打开终端执行 ccp add。名字有问题时不打开终端，返回 false。
    @discardableResult
    func add(_ name: String) -> Bool {
        guard !isOpening, problem(forNewName: name) == nil else { return false }
        open(commands.addCommand(name), pending: .adding(name))
        return true
    }

    /// 打开终端执行 ccp rm（ccp 自己确认、引导登出）。默认档案和当前档案什么都不做。
    func remove(_ name: String, currentProfile: String) {
        guard !isOpening, removalBlocker(profile: name, currentProfile: currentProfile) == nil
        else { return }
        open(commands.removeCommand(name), pending: .removing(name))
    }

    /// 删除入口是否可用（默认档案、当前档案不能删除，规则与 ccp rm 相同）
    func removalBlocker(profile: String, currentProfile: String) -> ProfileCommands.RemovalBlocker? {
        commands.removalBlocker(profile: profile, currentProfile: currentProfile)
    }

    /// 档案列表变化时调用：进行中的添加或删除完成了就清除
    func update(with profiles: [Profile]) {
        if let pending, pending.isFinished(in: profiles) { self.pending = nil }
    }

    func dismissPending() { pending = nil }

    // MARK: 打开终端

    private func open(_ command: String, pending change: ProfileCommands.PendingChange) {
        isOpening = true
        Task {
            defer { isOpening = false }
            let permission = await Task.detached { Self.terminalPermission() }.value
            if permission == .denied {
                showManualCommand(command, reason: .notAuthorized)
                return
            }
            let explained = UserDefaults.standard.bool(forKey: Self.explainedKey)
            if permission.needsExplanation(explainedBefore: explained) {
                UserDefaults.standard.set(true, forKey: Self.explainedKey)
                // 用户选择复制命令或取消：不打开终端（复制的命令执行后，列表同样会自动更新）
                guard explainAutomation(command) else { return }
            }
            let launcher = launcher
            let outcome = await Task.detached { launcher.run(command) }.value
            switch outcome {
            case .opened:
                pending = change
            case .notAuthorized:
                showManualCommand(command, reason: .notAuthorized)
            case .failed(let message):
                NSLog("CC Pilot: 打开终端失败：%@", message)
                showManualCommand(command, reason: .failed(message))
            }
        }
    }

    /// 不弹窗地查询 CC Pilot 能否控制"终端"
    nonisolated private static func terminalPermission() -> TerminalLauncher.Permission {
        let target = NSAppleEventDescriptor(bundleIdentifier: TerminalLauncher.terminalBundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        return TerminalLauncher.Permission(status: status)
    }

    /// 系统即将请求自动化授权：先说明为什么需要，以及会在终端里执行的命令。返回是否继续打开终端。
    private func explainAutomation(_ command: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "CC Pilot will open Terminal")
        alert.informativeText = String(localized: """
            To add or delete a profile, CC Pilot opens a new Terminal window and runs the command below there. \
            macOS will ask whether CC Pilot may control Terminal; CC Pilot uses this only to run this command.

            If you’d rather not allow it, copy the command and run it in a terminal yourself.
            """)
        alert.accessoryView = Self.commandView(command)
        alert.addButton(withTitle: String(localized: "Open Terminal"))
        alert.addButton(withTitle: String(localized: "Copy Command"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertSecondButtonReturn { Self.copy(command) }
        return response == .alertFirstButtonReturn
    }

    private enum ManualReason { case notAuthorized, failed(String) }

    /// 打不开终端：给出可以复制到终端手动执行的命令
    private func showManualCommand(_ command: String, reason: ManualReason) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Couldn’t open Terminal")
        switch reason {
        case .notAuthorized:
            alert.informativeText = String(localized: """
                CC Pilot isn’t allowed to control Terminal. Copy the command below and run it in a terminal yourself.

                To let CC Pilot open Terminal for you, turn on Terminal under CC Pilot in \
                System Settings > Privacy & Security > Automation.
                """)
        case .failed(let message):
            alert.informativeText = String(localized: "Copy the command below and run it in a terminal yourself.")
                + "\n\n" + message
        }
        alert.accessoryView = Self.commandView(command)
        alert.addButton(withTitle: String(localized: "Copy Command"))
        if case .notAuthorized = reason {
            alert.addButton(withTitle: String(localized: "Open System Settings"))
        }
        alert.addButton(withTitle: String(localized: "Close"))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Self.copy(command)
        } else if case .notAuthorized = reason, response == .alertSecondButtonReturn,
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// 等宽、可选中复制的命令
    private static func commandView(_ command: String) -> NSView {
        let field = NSTextField(labelWithString: command)
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.isSelectable = true
        field.lineBreakMode = .byCharWrapping
        field.preferredMaxLayoutWidth = 360
        field.frame.size = field.fittingSize
        return field
    }
}
