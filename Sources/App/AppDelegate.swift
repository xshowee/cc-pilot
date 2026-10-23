// 在 App 启动时就要存在、与面板是否打开无关的对象。
// MenuBarExtra 的面板内容在第一次打开时才构建，放在那里的对象不会在启动时创建；
// Sparkle 的每日定时检查必须从启动开始算，所以 Updater 放在这里。

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let updater = Updater()
    @MainActor let launchAtLogin = LaunchAtLoginModel()
}
