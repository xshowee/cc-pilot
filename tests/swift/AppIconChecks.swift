// ticket 17：菜单栏"只显示图标"用的模板图（Resources/MenuBarIcon*.png，由 scripts/make-icons.sh 生成）。
// chatgpt-profiles ticket 03：两个工具的图标（Resources/<Tool.iconResourceName(用途)>*.png，同样由 make-icons.sh 生成），
// 面板分割线、菜单栏行首、菜单栏两行文字左侧各一种尺寸，也是模板图。
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
            for use in ToolIconResource.Use.allCases {
                for (scale, suffix) in [(1, ".png"), (2, "@2x.png")] {
                    let name = tool.iconResourceName(use) + suffix
                    let side = ToolIconResource.points(use, tool) * scale
                    checks.append(Check("\(tool.displayName) 的图标 \(name) 是 \(side) 像素见方的单色模板图") {
                        let url = repoRoot.appendingPathComponent("Resources/\(name)")
                        try expectPixels(url, side)
                        // ChatGPT 图标线条细，10–12 像素时几乎全是抗锯齿的半透明像素，不要求有完全不透明的像素
                        try expectMonochrome(url, solidAlpha: 0.5)
                    })
                }
            }
        }
        checks.append(Check("每个工具、每种用途的图标资源名都不同") {
            let names = Tool.allCases.flatMap { tool in ToolIconResource.Use.allCases.map(tool.iconResourceName) }
            try expectEqual(Set(names).count, names.count)
        })
        checks.append(Check("菜单栏用的图标两行叠起来放得进 22pt 高的菜单栏") {
            for tool in Tool.allCases {
                let side = ToolIconResource.points(.menuBar, tool)
                try expect(side * 2 <= 22, "\(tool.displayName) 的菜单栏图标 \(side)pt 太高")
            }
        })
        checks.append(Check("两行文字左侧的图标放得进 22pt 高的菜单栏，且比行首图标大") {
            for tool in Tool.allCases {
                let side = ToolIconResource.points(.menuBarSummary, tool)
                try expect(side <= 22 && side > ToolIconResource.points(.menuBar, tool),
                           "\(tool.displayName) 的两行左侧图标 \(side)pt 不合适")
            }
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
