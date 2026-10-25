// 菜单栏面板打开时检查位置：过夜（显示器休眠、唤醒）后第一次打开，面板可能离开菜单栏、往下掉一截，
// 掉了就挪回菜单栏下（App 核心 MenuBarPanelPlacement；统计面板是它的子窗口，跟着一起挪）。
// 面板每次打开都会成为 key，以此作为"打开了"；等系统摆好位置后再检查。
// 挪动时往系统日志写一行当时的屏幕、可用区域、面板和菜单栏图标的位置，用来确认掉下来的原因：
// 用 os.Logger 而不是 NSLog：从访达或登录项启动时，NSLog 只写到 stderr，系统日志里查不到。
//   /usr/bin/log show --last 1d --predicate 'subsystem == "com.ccpilot.app" AND category == "panel"'

import AppKit
import os

@MainActor
final class PanelPositionGuard: ObservableObject {
    private static let log = Logger(subsystem: "com.ccpilot.app", category: "panel")

    private weak var window: NSWindow?
    private var observer: NSObjectProtocol?

    /// 主面板所在的窗口（WindowReader 报告）
    func attach(to window: NSWindow?) {
        guard window !== self.window else { return }
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        self.window = window
        guard let window else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                          object: window, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { Task { @MainActor in self?.check() } }
        }
        check()
    }

    private func check() {
        guard let window, window.isVisible, let screen = window.screen,
              let origin = MenuBarPanelPlacement.corrected(window.frame, within: screen.visibleFrame)
        else { return }
        let statusItem = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") }
        let iconFrame = statusItem.map { NSStringFromRect($0.frame) } ?? "未找到"
        Self.log.notice("""
            面板离开了菜单栏，已挪回：屏幕 \(NSStringFromRect(screen.frame), privacy: .public)，\
            可用区域 \(NSStringFromRect(screen.visibleFrame), privacy: .public)，\
            面板 \(NSStringFromRect(window.frame), privacy: .public)，菜单栏图标 \(iconFrame, privacy: .public)
            """)
        window.setFrameOrigin(origin)
    }
}
