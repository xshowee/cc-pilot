// 面板底部的设置菜单（齿轮图标）：顶部是"关于 CC Pilot"（ticket 27），然后是"登录时启动"、
// "菜单栏只显示图标"、zsh 接入（ticket 08）、"自动检查更新"、"检查更新…"。
// 定时检查发现新版本时，图标换成下载箭头，菜单项变成"有可用更新…"。
// Updater 和 LaunchAtLoginModel 在 App 启动时创建（CCPilotApp），通过 environmentObject 传进来。

import SwiftUI

struct SettingsMenu: View {
    @EnvironmentObject private var updater: Updater
    @EnvironmentObject private var launchAtLogin: LaunchAtLoginModel
    @EnvironmentObject private var shellIntegration: ShellIntegrationModel
    @AppStorage(MenuBarPreferences.iconOnlyKey) private var menuBarIconOnly = false

    var body: some View {
        Menu {
            Button("About CC Pilot") { AboutPanel.show() }
            Divider()
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            Toggle("Show only an icon in the menu bar", isOn: $menuBarIconOnly)
            if shellIntegration.isAvailable {
                if shellIntegration.isConnected {
                    Button("Remove zsh Integration…") { shellIntegration.disconnectWithConfirmation() }
                } else {
                    Button("Set Up zsh Integration…") { shellIntegration.connectWithConsent() }
                }
            }
            Divider()
            Toggle("Automatically Check for Updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticallyChecksForUpdates($0) }
            ))
            Divider()
            Button(updater.hasPendingUpdate
                   ? String(localized: "Update Available…")
                   : String(localized: "Check for Updates…")) {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        } label: {
            Image(systemName: updater.hasPendingUpdate ? "arrow.down.circle.fill" : "gearshape")
                .font(.system(size: 12, weight: .medium))
                .accessibilityLabel(Text("Settings"))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear {
            launchAtLogin.refresh()
            shellIntegration.refresh()
        }
    }
}
