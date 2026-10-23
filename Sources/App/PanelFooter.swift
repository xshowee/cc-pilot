// 面板底部的操作。后续 ticket 的设置、检查更新等入口加在这里。

import AppKit
import SwiftUI

struct PanelFooter: View {
    var body: some View {
        HStack {
            SettingsMenu()
            Spacer()
            Button("Quit CC Pilot") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
