// 提示框里显示一行命令（或 ~/.zshrc 的接入行）：等宽、可选中复制、按字符折行。
// ProfileActionsModel 和 ShellIntegrationModel 的提示框共用。

import AppKit

enum CommandTextView {
    static func make(_ text: String, fontSize: CGFloat = NSFont.systemFontSize) -> NSView {
        let field = NSTextField(labelWithString: text)
        field.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        field.isSelectable = true
        field.lineBreakMode = .byCharWrapping
        field.preferredMaxLayoutWidth = 360
        field.frame.size = field.fittingSize
        return field
    }
}
