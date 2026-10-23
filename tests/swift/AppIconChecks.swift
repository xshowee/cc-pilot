// ticket 17：菜单栏"只显示图标"用的模板图（Resources/MenuBarIcon*.png，由 scripts/make-icons.sh 生成）。
// 模板图（isTemplate）只看透明度，系统按菜单栏明暗着色；画面里混进别的颜色，在深色菜单栏下就会露出来。
// 尺寸与 App 图标的检查在 tests/shell/test-app-icon.zsh。

import AppKit

final class AppIconChecks: CheckSuite {
    override class var checks: [Check] {
        ["MenuBarIcon.png", "MenuBarIcon@2x.png"].map { name in
            Check("菜单栏模板图 \(name) 只有黑色与透明度") {
                try expectMonochrome(repoRoot.appendingPathComponent("Resources/\(name)"))
            }
        }
    }

    static func expectMonochrome(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
            throw CheckFailure(description: "读不出 \(url.path)")
        }
        var opaque = 0, clear = 0, colored: [String] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let alpha = color.alphaComponent
                if alpha < 0.01 { clear += 1; continue }
                if alpha > 0.99 { opaque += 1 }
                if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.02 {
                    colored.append("(\(x),\(y))")
                }
            }
        }
        try expect(colored.isEmpty, "\(url.lastPathComponent) 有非黑色的像素：\(colored.prefix(5).joined(separator: " "))")
        try expect(opaque > 0 && clear > 0, "\(url.lastPathComponent) 应同时有不透明与全透明的像素")
    }
}
