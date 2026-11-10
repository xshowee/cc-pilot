// 把机密（目前只有 Kimi Code 的 API key，ADR 0007）复制到剪贴板，过一段时间再清掉。
//
// 剪贴板上的机密会被别的 App 看到、记下或同步走，所以写入时（SecretPasteboard 的真实实现，App 里的
// SystemSecretPasteboard）：
// - 只留在本机：不经"通用剪贴板"同步到同一 Apple ID 的其他设备；
// - 标记为机密、临时（nspasteboard.org 的 ConcealedType、TransientType）：遵守约定的剪贴板管理工具不记进历史；
// 写入 clearAfter 之后，如果剪贴板还是这次写入的内容（changeCount 没变）就清空；期间用户复制了别的东西就不动，
// 免得清掉用户自己的内容。App 退出时同样只清自己写的那次（clearIfUnchanged）。
//
// 用法：let token = clipboard.copy(key) …… clearAfter 秒后 clipboard.clearIfUnchanged(since: token)

import Foundation

/// 剪贴板里复制机密要用到的部分（App 里是 NSPasteboard.general，检查程序里是假的）
protocol SecretPasteboard: AnyObject {
    /// 剪贴板内容每变一次就加一（同 NSPasteboard.changeCount）
    var changeCount: Int { get }
    /// 清空剪贴板并写入这段机密（只留本机、标记为机密和临时）；返回写入后的 changeCount
    func writeSecret(_ text: String) -> Int
    /// 清空剪贴板
    func clearContents()
}

struct SecretClipboard {
    /// 复制后多久清空剪贴板
    static let clearAfter: TimeInterval = 60

    let pasteboard: SecretPasteboard

    /// 复制；返回这次复制的凭证，到时交给 clearIfUnchanged
    func copy(_ secret: String) -> Int {
        pasteboard.writeSecret(secret)
    }

    /// 剪贴板还是凭证对应的那次写入时清空，返回是否清了；之后有过别的复制就不动
    @discardableResult
    func clearIfUnchanged(since token: Int) -> Bool {
        guard pasteboard.changeCount == token else { return false }
        pasteboard.clearContents()
        return true
    }
}
