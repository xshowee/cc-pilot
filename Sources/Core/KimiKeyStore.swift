// Kimi Code 账号的 API key 存在哪里（ADR 0007）。Kimi Code 只显示额度：本机没有可读取的登录状态，
// 额度接口要用户在 Kimi Code 控制台创建的 API key，所以这是 cc-pilot 唯一自己保存的凭据。
// 一个 Kimi Code 账号 = 用户起的名称 + 一个 API key；可以有多个。
//
// App 核心只通过 CoreEnvironment.kimiKeys 读写；检查程序换成内存里的假实现，绝不碰真实的钥匙串。
//
// 真实实现（KeychainKimiKeyStore）：登录钥匙串里每个账号一条通用密码项，service 为 serviceName、account 为账号名称。
// - 用 Security 框架直接读写，不经 /usr/bin/security：`add-generic-password -w <key>` 会把 key 放进命令行参数。
// - names 只查属性、不取内容：打开面板、启动 App 都不读 key，也不会弹出钥匙串授权窗口。
// - read 只在用户点刷新（KimiUsageRefresher）或"复制 API key"（KimiModel.copyKey，写进剪贴板后按
//   SecretClipboard 的规则清除）时调用，key 用完即丢，不缓存、不写盘、不记日志。
// - save 先删后加：钥匙串项的访问控制归写入它的 App，重新写入后读取不必再授权。

import Foundation
import Security

/// 可以在线程之间传递：刷新在后台队列上读 key
protocol KimiKeyStore: Sendable {
    /// 已保存 key 的账号名称，按名称排序（不读取 key 的内容）
    func names() -> [String]
    /// 读取这个账号的 key；没有、读不到（例如授权被拒）时为 nil
    func read(_ name: String) -> String?
    /// 保存这个账号的 key，替换原有的
    func save(_ key: String, for name: String) throws
    /// 移除这个账号的 key；本来就没有时不算失败
    func remove(_ name: String) throws
}

/// 钥匙串操作失败（只带状态码，不含 key）
struct KimiKeyStoreError: Error, Equatable {
    let status: Int32
}

/// Kimi Code 账号名称的规则：字符规则同档案名（ProfileName.isWellFormed），不能与已有的重名；没有保留名。
enum KimiAccountName {
    static func problem(_ name: String, existing: [String]) -> ProfileCommands.NewNameProblem? {
        if name.isEmpty { return .empty }
        if !ProfileName.isWellFormed(name) { return .malformed }
        if existing.contains(name) { return .exists }
        return nil
    }

    /// 去掉首尾空白后的 key；空的不能保存
    static func normalizedKey(_ input: String) -> String? {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

struct KeychainKimiKeyStore: KimiKeyStore {
    static let serviceName = "cc-pilot Kimi Code API key"

    private var service: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.serviceName]
    }

    private func item(_ name: String) -> [String: Any] {
        var item = service
        item[kSecAttrAccount as String] = name
        return item
    }

    func names() -> [String] {
        var query = service
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    func read(_ name: String) -> String? {
        var query = item(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    func save(_ key: String, for name: String) throws {
        try remove(name)
        var attributes = item(name)
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrLabel as String] = Self.serviceName
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KimiKeyStoreError(status: status) }
    }

    func remove(_ name: String) throws {
        let status = SecItemDelete(item(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KimiKeyStoreError(status: status) }
    }
}
