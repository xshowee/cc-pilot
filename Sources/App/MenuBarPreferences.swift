// 菜单栏显示方式的设置。存在 UserDefaults（App 的偏好设置域）里，App 重启后仍然保留。
// 用 @AppStorage(MenuBarPreferences.iconOnlyKey) 读写。

import SwiftUI

enum MenuBarPreferences {
    /// true：菜单栏只显示图标；false（默认）：显示当前档案名和额度两行
    static let iconOnlyKey = "menuBarIconOnly"
}

/// 面板里的"菜单栏只显示图标"开关
struct MenuBarIconOnlyToggle: View {
    @AppStorage(MenuBarPreferences.iconOnlyKey) private var iconOnly = false

    var body: some View {
        Toggle("Show only an icon in the menu bar", isOn: $iconOnly)
            .toggleStyle(.checkbox)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
