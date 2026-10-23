// "登录时启动"开关的界面状态。逻辑在 App 核心的 LaunchAtLogin；这里用 SMAppService.mainApp 实现系统登录项。
// 默认关闭：只有用户打开开关时才调用 register()。

import AppKit
import ServiceManagement
import SwiftUI

struct MainAppLoginItem: LoginItemService {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

@MainActor
final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var isEnabled: Bool

    private let setting: LaunchAtLogin

    init(service: LoginItemService = MainAppLoginItem()) {
        setting = LaunchAtLogin(service: service)
        isEnabled = setting.isEnabled
    }

    /// 重新读系统状态（用户可能在"系统设置 › 登录项"里改过）
    func refresh() {
        isEnabled = setting.isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try setting.setEnabled(enabled)
        } catch {
            showError(error)
        }
        refresh()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn’t change Launch at Login")
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
