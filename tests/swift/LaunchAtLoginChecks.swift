// ticket 14：App 核心"登录时启动"（LaunchAtLogin）。系统登录项用假的 LoginItemService 代替。

import Foundation

final class LaunchAtLoginChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("默认关闭：创建时不注册登录项，状态以系统为准", offByDefault),
            Check("打开开关时注册登录项，关闭时取消注册", togglesRegistration),
            Check("开关状态已与系统一致时不重复注册或取消", noOpWhenAlreadyInState),
            Check("注册失败时抛出错误，状态仍以系统为准", failureKeepsSystemState),
        ]
    }

    final class FakeLoginItems: LoginItemService {
        var isEnabled = false
        var calls: [String] = []
        var failure: Error?
        func register() throws {
            calls.append("register")
            if let failure { throw failure }
            isEnabled = true
        }
        func unregister() throws {
            calls.append("unregister")
            if let failure { throw failure }
            isEnabled = false
        }
    }

    struct Denied: Error {}

    static func offByDefault() throws {
        let items = FakeLoginItems()
        let setting = LaunchAtLogin(service: items)
        try expectEqual(setting.isEnabled, false)
        try expectEqual(items.calls, [], "创建时不应调用系统登录项")

        items.isEnabled = true   // 用户在"系统设置 › 登录项"里打开了
        try expectEqual(setting.isEnabled, true, "状态应总是读系统的")
    }

    static func togglesRegistration() throws {
        let items = FakeLoginItems()
        let setting = LaunchAtLogin(service: items)
        try setting.setEnabled(true)
        try expectEqual(setting.isEnabled, true)
        try setting.setEnabled(false)
        try expectEqual(setting.isEnabled, false)
        try expectEqual(items.calls, ["register", "unregister"])
    }

    static func noOpWhenAlreadyInState() throws {
        let items = FakeLoginItems()
        let setting = LaunchAtLogin(service: items)
        try setting.setEnabled(false)
        items.isEnabled = true
        try setting.setEnabled(true)
        try expectEqual(items.calls, [])
    }

    static func failureKeepsSystemState() throws {
        let items = FakeLoginItems()
        items.failure = Denied()
        let setting = LaunchAtLogin(service: items)
        var threw = false
        do { try setting.setEnabled(true) } catch is Denied { threw = true }
        try expect(threw, "注册失败应抛出系统给的错误")
        try expectEqual(setting.isEnabled, false)
    }
}
