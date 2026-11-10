// SecretPasteboard 的真实实现：系统剪贴板（NSPasteboard.general），规则见 Core 的 SecretClipboard。
// - prepareForNewContents(with: .currentHostOnly)：清空并声明这次的内容只留在本机，不经通用剪贴板同步；
// - 除了文字，再放两个空的标记类型 org.nspasteboard.ConcealedType、org.nspasteboard.TransientType
//   （nspasteboard.org 的约定）：剪贴板管理工具看到就不记进历史。

import AppKit

final class SystemSecretPasteboard: SecretPasteboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func writeSecret(_ text: String) -> Int {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.concealedType)
        pasteboard.setData(Data(), forType: Self.transientType)
        return pasteboard.changeCount
    }

    func clearContents() {
        pasteboard.clearContents()
    }
}
