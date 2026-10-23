// 档案名规则（与 shell/lib/profiles.zsh 的 _ccp_valid_name 一致）：^[A-Za-z0-9][A-Za-z0-9._-]*$
// 保留名：default（默认档案）、active（~/.claude-profiles/active 是当前档案记录文件）。

import Foundation

enum ProfileName {
    static let defaultName = "default"
    /// ~/.claude-profiles/ 下当前档案记录文件的名字
    static let activeRecordName = "active"
    static let reserved: Set<String> = [defaultName, activeRecordName]

    /// 名字是否符合字符规则（不考虑保留名）
    static func isWellFormed(_ name: String) -> Bool {
        // 按 Unicode 标量逐个判断，只接受 ASCII，避免把全角字母、组合字符算成合规
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, isAlnum(first) else { return false }
        return scalars.dropFirst().allSatisfy { isAlnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// 能否作为 ~/.claude-profiles/ 下的档案名：合规且不是保留名
    static func isProfileName(_ name: String) -> Bool {
        isWellFormed(name) && !reserved.contains(name)
    }

    private static func isAlnum(_ s: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s)
    }
}
