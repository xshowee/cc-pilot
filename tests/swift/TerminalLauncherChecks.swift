// ticket 09：App 打开终端执行 ccp add / ccp rm（App 核心 TerminalLauncher）。
// osascript 一律是假的（TempHome 注入 tests/fakes/fake-osascript），绝不真的打开终端、不触发自动化授权弹窗。

import Foundation

final class TerminalLauncherChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("打开终端：命令作为单独的参数交给 osascript，不拼进脚本", opensTerminalWithCommandAsArgument),
            Check("自动化授权被拒（-1743）时报告未授权", deniedAutomation),
            Check("其他失败时报告失败并带上 osascript 的说明", otherFailure),
            Check("是否需要先说明自动化授权", explanationNeeded),
        ]
    }

    static let command = "'/Applications/CC Pilot.app/Contents/Resources/shell/bin/ccp' add work"

    static func opensTerminalWithCommandAsArgument() throws {
        let home = try TempHome()
        defer { home.remove() }

        let outcome = TerminalLauncher(environment: home.environment).run(command)

        try expectEqual(outcome, .opened)
        let calls = home.osascriptCalls()
        try expectEqual(calls.count, 1, "应调用一次 osascript")
        let args = calls[0]
        try expectEqual(args.last, command, "最后一个参数就是命令原文")
        let script = args.dropLast().joined(separator: "\n")
        try expect(script.contains(#"tell application "Terminal""#) && script.contains("do script"),
                   "脚本应让 Terminal 执行命令：\(script)")
        try expect(!script.contains("ccp"), "命令不应拼进脚本里（避免引号和注入问题）：\(script)")
    }

    static func deniedAutomation() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.osascriptFails(exit: 1, stderr: "56:120: execution error: Not authorized to send Apple events to Terminal. (-1743)\n")

        try expectEqual(TerminalLauncher(environment: home.environment).run(command), .notAuthorized)
    }

    static func otherFailure() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.osascriptFails(exit: 1, stderr: "execution error: Terminal got an error: Application isn’t running. (-600)\n")

        let outcome = TerminalLauncher(environment: home.environment).run(command)

        guard case .failed(let message) = outcome else {
            throw CheckFailure(description: "应报告失败，得到 \(outcome)")
        }
        try expect(message.contains("(-600)"), "失败说明应带上 osascript 的输出：\(message)")
    }

    static func explanationNeeded() throws {
        typealias P = TerminalLauncher.Permission
        try expectEqual(P(status: 0), .granted)
        try expectEqual(P(status: -1743), .denied)
        try expectEqual(P(status: -1744), .notDetermined)
        try expectEqual(P(status: -600), .unknown)   // Terminal 没在运行时查不到

        // 已授权：直接打开；被拒：不用说明，直接给出手动执行的命令；未决定：每次都先说明
        try expectEqual(P.granted.needsExplanation(explainedBefore: false), false)
        try expectEqual(P.denied.needsExplanation(explainedBefore: false), false)
        try expectEqual(P.notDetermined.needsExplanation(explainedBefore: true), true)
        // 查不到时：没说明过就先说明一次
        try expectEqual(P.unknown.needsExplanation(explainedBefore: false), true)
        try expectEqual(P.unknown.needsExplanation(explainedBefore: true), false)
    }
}
