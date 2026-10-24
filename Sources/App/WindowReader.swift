// 报告 SwiftUI 视图所在的 NSWindow（放在 background 里，不占位置、不响应鼠标）。
// 统计面板（token-usage ticket 07）用它找到主面板窗口，把弹出面板挂成它的子窗口、按它的位置摆放。

import AppKit
import SwiftUI

struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var onChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [weak self] in self?.onChange?(window) }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
