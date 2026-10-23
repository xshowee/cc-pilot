// "关于 CC Pilot"（ticket 27）：打开系统标准关于面板。
// 图标、名称、版本与构建号、版权行都由系统从 Info.plist 读取（CFBundleIconFile、CFBundleName、
// CFBundleShortVersionString、CFBundleVersion、NSHumanReadableCopyright）；这里只补上 credits：
// MIT 许可证说明和项目主页链接（只是链接，点击后才由浏览器打开，App 本身不联网）。
// 标准关于面板是单例，重复打开只会把同一个面板拿到前面。

import AppKit

@MainActor
enum AboutPanel {
    static func show() {
        // App 是 LSUIElement，先激活到前台，面板才不会落在其他 App 的窗口后面
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    private static let homepage = "https://github.com/xshowee/cc-pilot"

    private static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(
            string: String(localized: "CC Pilot is open-source software released under the MIT License.") + "\n",
            attributes: base
        )
        var link = base
        link[.link] = URL(string: homepage)
        text.append(NSAttributedString(string: homepage, attributes: link))
        return text
    }
}
