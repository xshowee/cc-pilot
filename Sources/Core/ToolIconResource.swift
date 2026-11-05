// 工具图标（chatgpt-profiles ticket 03）：面板分割线、菜单栏行首（ticket 11）与只显示一个工具时菜单栏两行文字的左侧
// 用的位图资源，每种用途一个尺寸。
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
        /// 只显示一个工具时，菜单栏"套餐 / 5 小时剩余"两行文字的左侧，竖跨两行
        case menuBarSummary
    }

    /// 图标边长（pt）。scripts/render-icons.swift 按同样的数值出图（1x、@2x）。
    /// 菜单栏里的 Claude 图标大 1pt：它是一圈细射线、留白多，同样大小时看着比 ChatGPT 的小、虚
    static func points(_ use: Use, _ tool: Tool) -> Int {
        switch (use, tool) {
        case (.panel, _): return 12
        case (.menuBar, .claudeCode): return 11
        case (.menuBar, .chatgpt): return 10
        case (.menuBarSummary, .claudeCode): return 15
        case (.menuBarSummary, .chatgpt): return 14
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
        case .menuBarSummary: return base + "MenuBarSummaryIcon"
        }
    }
}
