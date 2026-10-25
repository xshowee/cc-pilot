// 侧边统计面板的窗口（token-usage ticket 07）：鼠标停在主面板的账号行上时，在主面板左侧弹出这个账号的统计面板。
//
// 窗口：一个不会成为 key 的非激活 NSPanel，作为主面板窗口（MenuBarExtra 的 .window）的子窗口。
//   不能成为 key 很要紧：MenuBarExtra 的窗口一失去 key 就会收起，点统计面板里的分段、清空按钮时它必须保持 key。
//   背景是与主面板相同的系统材质（从主面板窗口里找到它的 NSVisualEffectView、取同一种 material），跟随系统外观。
// 位置：每次显示、内容高度变化、主面板移动或改变大小时，按主面板此刻的位置重算（App 核心 StatsFlyoutPlacement），
//   贴着主面板左侧、顶边对齐，压在屏幕可用区域内。主面板过一夜后可能往下掉（PanelPositionGuard 在打开时挪回），这里不假设它在菜单栏下。
// 弹出与收起：鼠标在行与面板之间怎么移动由 App 核心 StatsFlyoutHover 判断；离开后等 0.25 秒再收起，
//   留出从行移到面板的时间。主面板关闭（PanelView 消失、窗口失去 key）时立即收起。

import AppKit
import SwiftUI

@MainActor
final class StatsFlyoutController: ObservableObject {
    /// 鼠标停在哪一行（档案名）；nil 时面板收起
    @Published private(set) var hover = StatsFlyoutHover()

    /// 离开行或面板后等多久再收起
    private static let settleDelay: TimeInterval = 0.25
    /// 与主面板之间的空隙
    private static let gap: CGFloat = 6
    private static let cornerRadius: CGFloat = 12

    private var panel: StatsFlyoutPanel?
    private var effectView: NSVisualEffectView?
    private weak var anchor: NSWindow?
    private var anchorObservers: [NSObjectProtocol] = []
    private var settleWork: DispatchWorkItem?
    /// 面板内容的大小（由 StatsFlyoutRoot 报告）
    private var contentSize = CGSize(width: StatsFlyoutRoot.width, height: 560)

    // MARK: - 接入

    /// 主面板所在的窗口（WindowReader 报告）
    func attach(to window: NSWindow?) {
        guard window !== anchor else { return }
        hide()
        anchorObservers.forEach(NotificationCenter.default.removeObserver)
        anchorObservers = []
        anchor = window
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didChangeScreenNotification] {
            anchorObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reposition() }
            })
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            anchorObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.dismiss() }
            })
        }
    }

    /// 面板内容（只装一次）
    func install<Content: View>(_ root: Content) {
        guard panel == nil else { return }
        let panel = StatsFlyoutPanel()
        let effect = NSVisualEffectView()
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.material = .popover
        effect.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        let hosting = StatsFlyoutHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)
        panel.contentView = effect
        hosting.frame = effect.bounds
        self.panel = panel
        effectView = effect
    }

    // MARK: - 鼠标

    /// 鼠标进入或离开一个有账号的档案行
    func row(_ name: String, hovering: Bool) {
        hover.row(name, hovering: hovering)
        if !hovering { scheduleSettle() }
        apply()
    }

    /// 鼠标进入或离开统计面板
    func flyout(hovering: Bool) {
        hover.flyout(hovering: hovering)
        if !hovering { scheduleSettle() }
    }

    /// 档案列表变了（rows 是有账号的档案名）：停着的行被删除或登出时收不到离开，在这里收起
    func rowsChanged(_ rows: Set<String>) {
        hover.rowsChanged(rows)
        apply()
    }

    /// 主面板关闭：立即收起
    func dismiss() {
        settleWork?.cancel()
        hover.dismiss()
        apply()
    }

    /// 面板内容的大小变了（分段切换、清空确认、模型行数）
    func contentSizeChanged(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != contentSize else { return }
        contentSize = size
        reposition()
    }

    // MARK: - 内部

    private func scheduleSettle() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // 面板不是 key 窗口，不确定 SwiftUI 的 onHover 在里面一定会触发，以鼠标的实际位置为准：
                // 还在面板上就过一会儿再看；不在面板上就一定没停在面板上
                if let panel = self.panel, panel.isVisible, panel.frame.contains(NSEvent.mouseLocation) {
                    self.scheduleSettle()
                    return
                }
                self.hover.flyout(hovering: false)
                self.hover.settle()
                self.apply()
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func apply() {
        if hover.profile == nil { hide() } else { show() }
    }

    private func show() {
        guard let panel, let anchor, anchor.isVisible else { return }
        if panel.parent == nil {
            effectView?.material = Self.material(in: anchor) ?? .popover
            panel.level = anchor.level
            reposition()
            anchor.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible { panel.orderFront(nil) }
    }

    private func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// 按主面板此刻的位置放好（不缓存位置，见文件头）
    private func reposition() {
        guard let panel, let anchor else { return }
        let screen = anchor.screen ?? NSScreen.screens.first { $0.frame.intersects(anchor.frame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor.frame
        let frame = StatsFlyoutPlacement.frame(size: contentSize, beside: anchor.frame, within: visible, gap: Self.gap)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    /// 主面板窗口背景用的材质（MenuBarExtra 内部的视图层次不公开，找不到时用 popover）
    private static func material(in window: NSWindow) -> NSVisualEffectView.Material? {
        func find(_ view: NSView) -> NSVisualEffectView? {
            if let effect = view as? NSVisualEffectView { return effect }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        return find(root)?.material
    }

    /// 圆角遮罩（可拉伸）：给 NSVisualEffectView 切出圆角，窗口阴影随之是圆角
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// 统计面板的窗口：无边框、不激活 App、永远不成为 key（见文件头）
final class StatsFlyoutPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: StatsFlyoutRoot.width, height: 560),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 面板不是 key 窗口，第一次点击也要直接交给按钮
private final class StatsFlyoutHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
