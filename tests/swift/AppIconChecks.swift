// ticket 17：菜单栏"只显示图标"用的模板图（Resources/MenuBarIcon*.png，由 scripts/make-icons.sh 生成）。
// chatgpt-profiles ticket 03：两个工具的图标（Resources/<Tool.iconResourceName>*.png，同样由 make-icons.sh 生成），
// 面板分割线与菜单栏行首共用，也是模板图。
// 模板图（isTemplate）只看透明度，系统按菜单栏明暗着色；画面里混进别的颜色，在深色菜单栏下就会露出来。
// 尺寸与 App 图标的检查在 tests/shell/test-app-icon.zsh。

import AppKit

final class AppIconChecks: CheckSuite {
    override class var checks: [Check] {
        menuBarIconChecks + toolIconChecks
    }

    static var menuBarIconChecks: [Check] {
        ["MenuBarIcon.png", "MenuBarIcon@2x.png"].map { name in
            Check("菜单栏模板图 \(name) 只有黑色与透明度") {
                try expectMonochrome(repoRoot.appendingPathComponent("Resources/\(name)"))
            }
        }
    }

    static var toolIconChecks: [Check] {
        var checks: [Check] = []
        for tool in Tool.allCases {
            for (scale, suffix) in [(1, ".png"), (2, "@2x.png")] {
                let name = tool.iconResourceName + suffix
                let side = ToolIconResource.points * scale
                checks.append(Check("\(tool.displayName) 的图标 \(name) 是 \(side) 像素见方的单色模板图") {
                    let url = repoRoot.appendingPathComponent("Resources/\(name)")
                    try expectPixels(url, side)
                    // ChatGPT 图标线条细，12 像素时几乎全是抗锯齿的半透明像素，不要求有完全不透明的像素
                    try expectMonochrome(url, solidAlpha: 0.5)
                })
            }
        }
        checks.append(Check("两个工具的图标资源名不同") {
            try expectEqual(Set(Tool.allCases.map(\.iconResourceName)).count, Tool.allCases.count)
        })
        return checks
    }

    static func expectPixels(_ url: URL, _ side: Int) throws {
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
            throw CheckFailure(description: "读不出 \(url.path)")
        }
        try expectEqual("\(rep.pixelsWide)x\(rep.pixelsHigh)", "\(side)x\(side)", "\(url.lastPathComponent) 的像素尺寸")
    }

    /// 只有黑色与透明度，且既有全透明的像素、也有透明度不低于 solidAlpha 的像素（不是空白图）
    static func expectMonochrome(_ url: URL, solidAlpha: CGFloat = 0.99) throws {
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
            throw CheckFailure(description: "读不出 \(url.path)")
        }
        var opaque = 0, clear = 0, colored: [String] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let alpha = color.alphaComponent
                if alpha < 0.01 { clear += 1; continue }
                if alpha >= solidAlpha { opaque += 1 }
                if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.02 {
                    colored.append("(\(x),\(y))")
                }
            }
        }
        try expect(colored.isEmpty, "\(url.lastPathComponent) 有非黑色的像素：\(colored.prefix(5).joined(separator: " "))")
        try expect(opaque > 0 && clear > 0, "\(url.lastPathComponent) 应同时有不透明（≥ \(solidAlpha)）与全透明的像素")
    }
}
