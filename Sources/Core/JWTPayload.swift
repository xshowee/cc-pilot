// 解码 JWT 的载荷（第二段，base64url，不补 =）。只读载荷，不校验签名：cc-pilot 只用它显示账号资料、
// 判断是否过期，不据此授权任何东西。失败时返回 nil，不带任何令牌内容。

import Foundation

enum JWTPayload {
    static func decode(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
