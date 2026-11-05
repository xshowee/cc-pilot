// 菜单栏面板打开时的位置校正：过夜（显示器休眠、唤醒）后第一次打开，面板顶边可能离开菜单栏、往下掉一截；
// 掉了就挪回菜单栏下，没掉不动。
//
// 检查的接口（seam）：
//   MenuBarPanelPlacement.corrected(_:within:)   面板此刻的位置 + 所在屏幕的可用区域 → 挪回后的原点，或 nil
// 数字取自实测：2560×1440 的屏幕，可用区域 (0, 59, 2560, 1351)（顶边 1410），正常打开时面板顶边 1408。

import Foundation

final class MenuBarPanelPlacementChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("菜单栏面板：顶边贴着菜单栏时不动；往下掉了就挪回菜单栏下，横向不变", corrected),
            Check("档案列表的最大高度：可用区域高减去菜单栏下的间隙、底部留白和列表以外的部分，屏幕再矮也有下限",
                  listHeightLimit),
        ]
    }

    static func corrected() throws {
        let visible = CGRect(x: 0, y: 59, width: 2560, height: 1351)
        func fix(_ frame: CGRect, _ within: CGRect = visible) -> CGPoint? {
            MenuBarPanelPlacement.corrected(frame, within: within)
        }
        try expectEqual(fix(CGRect(x: 1982, y: 1041, width: 340, height: 367)), nil, "正常位置")
        // 真机复现：顶边掉了 360pt（屏幕高 1440 与 1080 之差）
        try expectEqual(fix(CGRect(x: 1982, y: 681, width: 340, height: 367)),
                        CGPoint(x: 1982, y: 1041))
        try expectEqual(fix(CGRect(x: 1982, y: 1001, width: 340, height: 367)), nil, "只低 40pt：在容差内")
        // 菜单栏自动隐藏：可用区域顶到屏幕顶边，面板仍在菜单栏的位置下面，比可用区域顶边低一个菜单栏高度
        try expectEqual(fix(CGRect(x: 1982, y: 1041, width: 340, height: 367),
                            CGRect(x: 0, y: 59, width: 2560, height: 1381)), nil, "菜单栏自动隐藏")
        // 副屏（原点不在 0）
        try expectEqual(fix(CGRect(x: -500, y: 200, width: 340, height: 400),
                            CGRect(x: -1920, y: 300, width: 1920, height: 1050)),
                        CGPoint(x: -500, y: 948))
    }

    static func listHeightLimit() throws {
        let visible = CGRect(x: 0, y: 59, width: 2560, height: 1351)
        // 1351 - 2（菜单栏下的间隙）- 8（底部留白）- 141（标题、底栏等）
        try expectEqual(MenuBarPanelPlacement.listHeightLimit(chrome: 141, within: visible), 1200)
        // 副屏原点不影响结果，只看高度
        try expectEqual(MenuBarPanelPlacement.listHeightLimit(chrome: 141, within: visible.offsetBy(dx: -2560, dy: 300)),
                        1200)
        // 屏幕很矮（或列表以外的部分很高）时不小于下限
        try expectEqual(MenuBarPanelPlacement.listHeightLimit(chrome: 600, within: CGRect(x: 0, y: 0, width: 1280, height: 700)),
                        MenuBarPanelPlacement.minimumListHeight)
    }
}
