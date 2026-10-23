// ticket 12（spec Out of Scope）：App 不发送任何系统通知，包括低额度提醒。
// 界面不做自动化测试，这里检查源码里没有用到任何系统通知的接口。

import Foundation

final class NoNotificationChecks: CheckSuite {
    override class var checks: [Check] {
        [Check("App 源码不使用任何系统通知接口", noNotificationAPIs)]
    }

    static let forbidden = ["UserNotifications", "UNUserNotificationCenter", "UNMutableNotificationContent",
                            "NSUserNotification", "deliverNotification"]

    static func noNotificationAPIs() throws {
        var scanned = 0
        for dir in ["Sources/Core", "Sources/App"] {
            let url = repoRoot.appendingPathComponent(dir)
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) where name.hasSuffix(".swift") {
                let text = try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
                scanned += 1
                for word in forbidden {
                    try expect(!text.contains(word), "\(dir)/\(name) 用到了系统通知接口 \(word)")
                }
            }
        }
        try expect(scanned > 10, "应扫描到 App 源码，实际 \(scanned) 个文件")
        let plist = try String(contentsOf: repoRoot.appendingPathComponent("Resources/Info.plist"), encoding: .utf8)
        try expect(!plist.contains("NSUserNotification"), "Info.plist 不应声明通知")
    }
}
