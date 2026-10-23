// 面板底栏：左边"添加档案…"（点开后输入框出现在底栏上方，见 AddProfileForm），右边设置菜单和退出（⌘Q）。

import AppKit
import SwiftUI

struct PanelFooter: View {
    /// 输入框已打开、或正在打开终端时不可用
    var addDisabled = false
    let onAddProfile: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onAddProfile) {
                Label("Add Profile…", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(addDisabled)
            Spacer()
            SettingsMenu()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .keyboardShortcut("q")
            .help(Text("Quit CC Pilot"))
            .accessibilityLabel(Text("Quit CC Pilot"))
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
    }
}
