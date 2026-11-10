// 假的 Kimi Code key 存放处：替换 App 核心的 KimiKeyStore，key 只在内存里。
// TempHome 默认就注入一个（没有 key），检查程序绝不会读写真实的钥匙串。

import Foundation

// 可变状态都由 lock 保护
final class FakeKimiKeyStore: KimiKeyStore, @unchecked Sendable {
    private var keys: [String: String] = [:]
    private var unreadable = false
    private var reads = 0
    private let lock = NSLock()

    /// read 被调用的次数（names 不算）
    var readCount: Int { lock.withLock { reads } }

    /// 让之后的 read 读不到 key（模拟钥匙串授权被拒）；key 仍然存在
    func makeUnreadable() { lock.withLock { unreadable = true } }

    func names() -> [String] { lock.withLock { keys.keys.sorted() } }

    func read(_ name: String) -> String? {
        lock.withLock {
            reads += 1
            return unreadable ? nil : keys[name]
        }
    }

    func save(_ key: String, for name: String) throws { lock.withLock { keys[name] = key } }

    func remove(_ name: String) throws { lock.withLock { keys[name] = nil } }
}
