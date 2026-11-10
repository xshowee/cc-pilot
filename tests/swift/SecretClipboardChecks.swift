// 复制机密后的自动清除（SecretClipboard）：只清自己写入的那次，期间用户复制了别的就不动。剪贴板是假的。

import Foundation

final class SecretClipboardChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("复制时整段写入一次，写入后的 changeCount 就是凭证", copyWritesOnce),
            Check("剪贴板没被别的内容覆盖时清空", clearsOwnContents),
            Check("期间复制了别的东西就不清，也不覆盖", keepsLaterContents),
            Check("再复制一次后，旧凭证不会清掉新的内容", olderTokenDoesNotClearNewerCopy),
        ]
    }

    /// 假剪贴板：记下内容和 changeCount
    final class FakePasteboard: SecretPasteboard {
        private(set) var changeCount = 0
        private(set) var contents: String?
        private(set) var secretWrites = 0

        func writeSecret(_ text: String) -> Int {
            secretWrites += 1
            contents = text
            changeCount += 1
            return changeCount
        }

        func clearContents() {
            contents = nil
            changeCount += 1
        }

        /// 模拟用户在别的 App 里复制
        func userCopies(_ text: String) {
            contents = text
            changeCount += 1
        }
    }

    static let secret = "sk-kimi-FAKE-check-key-0000"

    static func copyWritesOnce() throws {
        let board = FakePasteboard()
        let token = SecretClipboard(pasteboard: board).copy(secret)
        try expectEqual(board.contents, secret)
        try expectEqual(board.secretWrites, 1)
        try expectEqual(token, board.changeCount)
    }

    static func clearsOwnContents() throws {
        let board = FakePasteboard()
        let clipboard = SecretClipboard(pasteboard: board)
        let token = clipboard.copy(secret)
        try expect(clipboard.clearIfUnchanged(since: token), "应当清空")
        try expectEqual(board.contents, nil)
    }

    static func keepsLaterContents() throws {
        let board = FakePasteboard()
        let clipboard = SecretClipboard(pasteboard: board)
        let token = clipboard.copy(secret)
        board.userCopies("hello")
        try expect(!clipboard.clearIfUnchanged(since: token), "不应清空")
        try expectEqual(board.contents, "hello")
    }

    static func olderTokenDoesNotClearNewerCopy() throws {
        let board = FakePasteboard()
        let clipboard = SecretClipboard(pasteboard: board)
        let first = clipboard.copy(secret)
        let second = clipboard.copy("sk-kimi-FAKE-check-key-1111")
        try expect(!clipboard.clearIfUnchanged(since: first), "旧凭证不应清空")
        try expectEqual(board.contents, "sk-kimi-FAKE-check-key-1111")
        try expect(clipboard.clearIfUnchanged(since: second), "新凭证应当清空")
    }
}
