// 钥匙串 service 名（spec "钥匙串 service 名"，与 Claude Code 2.1.309 的实现一致）：
//   默认档案（不设置 CLAUDE_CONFIG_DIR）：Claude Code-credentials
//   其他档案：Claude Code-credentials- 加上 sha256(NFC(配置目录字符串)) 十六进制的前 8 位。
//   对传给 CLAUDE_CONFIG_DIR 的原始字符串计算：不展开 ~，不去掉结尾的 /。
// 必须与 shell/lib/keychain.zsh 的 _ccp_service_name 完全一致（测试向量 tests/fixtures/service-names.tsv）。

import CryptoKit
import Foundation

enum KeychainServiceName {
    static let base = "Claude Code-credentials"

    /// - configDir: 传给 CLAUDE_CONFIG_DIR 的字符串；nil 表示默认档案
    static func forConfigDir(_ configDir: String?) -> String {
        guard let configDir else { return base }
        let nfc = configDir.precomposedStringWithCanonicalMapping
        let hex = SHA256.hash(data: Data(nfc.utf8)).map { String(format: "%02x", $0) }.joined()
        return base + "-" + hex.prefix(8)
    }
}

extension Profile {
    /// 这个档案的凭据在钥匙串里的 service 名
    var keychainService: String { KeychainServiceName.forConfigDir(configDir) }
}
