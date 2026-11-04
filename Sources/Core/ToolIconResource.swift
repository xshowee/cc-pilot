// 工具图标（chatgpt-profiles ticket 03）：面板分割线与菜单栏行首（ticket 11）共用的一套位图资源。
// 源文件是 Resources/Icons/claude.svg、chatgpt.svg，由 scripts/make-icons.sh 生成
// Resources/<iconResourceName>.png 与 @2x（单色模板图，黑色 + 透明度），随仓库提交，build-app.sh 只复制。
// 用位图而不在运行时解析 SVG，与菜单栏图标（MenuBarIcon，ticket 17）同一做法。
// App 里通过 ToolIcon（Sources/App/ToolIcon.swift）取图。

import Foundation

enum ToolIconResource {
    /// 图标边长（pt）：与菜单栏 22pt 高、两行 10.5pt 的文字同排（每行约 11pt）时大小相当，
    /// 面板分割线也用这个大小。scripts/render-icons.swift 按同一数值出图（1x、@2x）。
    static let points = 12
}

extension Tool {
    /// App 包 Contents/Resources 里图标的资源名（不含扩展名与 @2x）
    var iconResourceName: String {
        switch self {
        case .claudeCode: return "ClaudeIcon"
        case .chatgpt: return "ChatGPTIcon"
        }
    }
}
