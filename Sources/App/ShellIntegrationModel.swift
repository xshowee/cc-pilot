// 安装 ccp 与 zsh 接入的界面部分（ticket 08）。逻辑在 App 核心的 ShellIntegration：
// 安装就是把 App 内置的 Contents/Resources/shell/ 复制为 ~/.cc-pilot/，接入和移除执行 ccp init --yes / ccp uninstall。
//
// - App 启动时（AppDelegate）调用 startup()：已安装过就静默更新到内置版本；首次运行先说明再询问。
// - 用户回答过（同意或拒绝）就记在 UserDefaults 里，之后不再主动询问；拒绝后可从设置菜单重新发起。
// - 设置菜单里的"接入 zsh…"/"移除 zsh 接入…"调用 connectWithConsent() / disconnectWithConfirmation()。

import AppKit
import Foundation

@MainActor
final class ShellIntegrationModel: ObservableObject {
    /// UserDefaults 键：是否已经问过用户要不要接入（无论同意还是拒绝）
    static let askedKey = "shellIntegrationAsked"

    /// ~/.zshrc 里是否有接入行（终端里也可能 ccp init / ccp uninstall，菜单打开时用 refresh() 重读）
    @Published private(set) var isConnected = false

    private let integration: ShellIntegration?

    init(environment: CoreEnvironment = .live) {
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("shell", isDirectory: true),
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("bin/ccp").path) {
            integration = ShellIntegration(environment: environment, bundledShell: resources)
        } else {
            // 不是从 .app 运行（例如直接运行编译出的可执行文件）：没有内置的 shell/，不安装也不询问
            NSLog("CC Pilot: App 里没有内置的 shell/，跳过 ccp 的安装")
            integration = nil
        }
        refresh()
    }

    var isAvailable: Bool { integration != nil }

    func refresh() {
        let latest = integration?.isConnected ?? false
        if latest != isConnected { isConnected = latest }
    }

    /// App 启动时调用一次
    func startup() {
        guard let integration else { return }
        let asked = UserDefaults.standard.bool(forKey: Self.askedKey)
        do {
            if try integration.prepareAtLaunch(alreadyAsked: asked) == .askToConnect {
                connectWithConsent()
            }
        } catch {
            // 更新已安装的 ccp 失败不打扰用户：旧版本仍可用，下次启动再试
            NSLog("CC Pilot: 更新 ~/.cc-pilot 失败：%@", String(describing: error))
        }
        refresh()
    }

    /// 说明要对 ~/.zshrc 做的修改，用户同意后安装并接入。拒绝时不修改任何文件。
    func connectWithConsent() {
        guard let integration else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Set up the ccp command in zsh?")
        alert.informativeText = String(localized: """
            CC Pilot will install the ccp command and the claude wrapper function into ~/.cc-pilot, \
            then add the line below to the end of ~/.zshrc. Nothing else in ~/.zshrc is changed.

            You can remove this line later from CC Pilot’s settings, or by running ccp uninstall.
            """)
        alert.accessoryView = Self.lineView(ShellIntegration.zshrcLine)
        alert.addButton(withTitle: String(localized: "Add to ~/.zshrc"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        guard response == .alertFirstButtonReturn else { return }

        do {
            try integration.connect()
            refresh()
            inform(String(localized: "zsh is set up"),
                   String(localized: "Open a new terminal window to use ccp, or run source ~/.zshrc in an open one."))
        } catch {
            refresh()
            inform(String(localized: "Couldn’t set up zsh"), String(describing: error), style: .warning)
        }
    }

    /// 确认后执行 ccp uninstall：只删除 ~/.zshrc 里的接入行
    func disconnectWithConfirmation() {
        guard let integration else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove the cc-pilot line from ~/.zshrc?")
        alert.informativeText = String(localized: """
            This removes the line below, the same as running ccp uninstall. \
            New terminal windows will no longer load cc-pilot; claude will run without profiles.
            """)
        alert.accessoryView = Self.lineView(ShellIntegration.zshrcLine)
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try integration.disconnect()
        } catch {
            inform(String(localized: "Couldn’t remove the line from ~/.zshrc"), String(describing: error),
                   style: .warning)
        }
        refresh()
    }

    private func inform(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 等宽、可选中复制的一行文字
    private static func lineView(_ line: String) -> NSView {
        let field = NSTextField(labelWithString: line)
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.isSelectable = true
        field.lineBreakMode = .byCharWrapping
        field.preferredMaxLayoutWidth = 360
        field.frame.size = field.fittingSize
        return field
    }
}
