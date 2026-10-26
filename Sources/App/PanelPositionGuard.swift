// 菜单栏面板打开时检查位置：过夜（显示器休眠、唤醒）后第一次打开，面板可能离开菜单栏、往下掉一截，
// 掉了就挪回菜单栏下（App 核心 MenuBarPanelPlacement；统计面板是它的子窗口，跟着一起挪）。
// 面板每次打开都会成为 key，以此作为"打开了"；等系统摆好位置后再检查。

import AppKit

@MainActor
final class PanelPositionGuard: ObservableObject {
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
        window.setFrameOrigin(origin)
    }
}
