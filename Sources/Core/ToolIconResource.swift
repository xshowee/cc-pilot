// 工具图标（chatgpt-profiles ticket 03）：面板分割线与菜单栏行首（ticket 11）用的位图资源，两种用途各一个尺寸。
// 源文件是 Resources/Icons/claude.svg、chatgpt.svg，由 scripts/make-icons.sh 生成
// Resources/<iconResourceName(用途)>.png 与 @2x（单色模板图，黑色 + 透明度），随仓库提交，build-app.sh 只复制。
// 用位图而不在运行时解析 SVG，与菜单栏图标（MenuBarIcon，ticket 17）同一做法；小尺寸单独出图，不靠缩放。
// App 里通过 ToolIcon（Sources/App/ToolIcon.swift）取图。

import Foundation

enum ToolIconResource {
    enum Use: CaseIterable, Sendable {
        /// 面板里两段之间的分割线
        case panel
        /// 菜单栏一行 10.5pt 文字的行首（22pt 高的菜单栏放两行，每行约 11pt）
        case menuBar
    }

    /// 图标边长（pt）。scripts/render-icons.swift 按同样的数值出图（1x、@2x）
    static func points(_ use: Use) -> Int {
        switch use {
        case .panel: return 12
        case .menuBar: return 10
        }
    }
}

extension Tool {
    /// App 包 Contents/Resources 里图标的资源名（不含扩展名与 @2x）
    func iconResourceName(_ use: ToolIconResource.Use) -> String {
        let base: String
        switch self {
        case .claudeCode: base = "Claude"
        case .chatgpt: base = "ChatGPT"
        }
        switch use {
        case .panel: return base + "Icon"
        case .menuBar: return base + "MenuBarIcon"
        }
    }
}
