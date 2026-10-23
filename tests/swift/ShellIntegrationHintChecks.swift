// ticket 25：未接入 zsh 时面板提示"切换不会对终端里的 claude 生效"。
// 接入状态取自 ~/.zshrc（ShellIntegration.isConnected，规则由 ShellIntegrationChecks 检查）；
// 这里检查什么时候提示：App 带内置 shell/ 且未接入时提示，接入后、或不是从 .app 运行时不提示。

import Foundation

final class ShellIntegrationHintChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("未接入时面板提示切换不会对终端生效", hintWhenNotConnected),
            Check("已接入时不提示", noHintWhenConnected),
            Check("不是从 .app 运行（没有内置 shell/）时不提示", noHintWhenUnavailable),
            Check("终端里 ccp init / ccp uninstall 后，重新读取的提示状态随之变化", hintFollowsTerminal),
        ]
    }

    static func hintWhenNotConnected() throws {
        try expect(ShellIntegration.showsNotConnectedHint(available: true, connected: false), "未接入时应提示")
    }

    static func noHintWhenConnected() throws {
        try expect(!ShellIntegration.showsNotConnectedHint(available: true, connected: true), "已接入时不应提示")
    }

    static func noHintWhenUnavailable() throws {
        try expect(!ShellIntegration.showsNotConnectedHint(available: false, connected: false),
                   "不是从 .app 运行时不应提示")
    }

    static func hintFollowsTerminal() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.write(".zshrc", "export FOO=1\n")
        let integration = ShellIntegrationChecks.integration(home)
        func hint() -> Bool { ShellIntegration.showsNotConnectedHint(available: true, connected: integration.isConnected) }

        try expect(hint(), "接入前应提示")
        try integration.connect()
        try expect(!hint(), "ccp init 后不应提示")
        try integration.disconnect()
        try expect(hint(), "ccp uninstall 后应重新提示")
    }
}
