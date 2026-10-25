// 菜单栏面板（MenuBarExtra 的 .window）打开时的位置校正。
// 过夜（显示器休眠、唤醒）后第一次打开，面板顶边可能离开菜单栏、往下掉一截（两次真机复现都掉了约 360pt，
// 正好是屏幕高 1440 与 1080 之差，猜测是显示器重连时先按较低的分辨率接上、菜单栏图标的位置没跟着更新）。
// 系统每次打开都会重新定位面板，所以只在打开时对照所在屏幕的可用区域检查，掉了就挪回菜单栏下。

import CoreGraphics

enum MenuBarPanelPlacement {
    /// 正常打开时面板顶边比可用区域顶边低这么多（实测）
    static let gap: CGFloat = 2
    /// 比正常位置低出这么多才算掉下来：菜单栏自动隐藏时面板本来就低一个菜单栏高度，不算
    static let tolerance: CGFloat = 60

    /// 面板掉下来时返回挪回菜单栏下的原点（左下角，横向不变）；没掉返回 nil
    /// - frame: 面板窗口此刻的位置
    /// - visible: 面板所在屏幕的可用区域（visibleFrame）
    static func corrected(_ frame: CGRect, within visible: CGRect) -> CGPoint? {
        let top = visible.maxY - gap
        guard frame.maxY < top - tolerance else { return nil }
        return CGPoint(x: frame.minX, y: top - frame.height)
    }
}
