// 主面板所在屏幕的可用区域（visibleFrame）：档案列表按它决定最多多高（MenuBarPanelPlacement.listHeightLimit），
// 放不下时才滚动。面板打开（成为 key）、换了屏幕、屏幕参数变了（分辨率、程序坞、接上或拔掉显示器）时重新读取。

import AppKit

@MainActor
final class PanelScreenTracker: ObservableObject {
    /// 面板所在屏幕的可用区域；还不知道面板在哪个屏幕时为 nil
    @Published private(set) var visibleFrame: CGRect?

    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    /// 主面板所在的窗口（WindowReader 报告）
    func attach(to window: NSWindow?) {
        guard window !== self.window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        self.window = window
        guard let window else { return }
        let center = NotificationCenter.default
        let refresh: (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async { Task { @MainActor in self?.update() } }
        }
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main, using: refresh),
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main, using: refresh),
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main,
                               using: refresh),
        ]
        update()
    }

    private func update() {
        guard let frame = window?.screen?.visibleFrame, frame != visibleFrame else { return }
        visibleFrame = frame
    }
}
