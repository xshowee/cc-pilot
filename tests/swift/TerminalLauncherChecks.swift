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
            Check("shell 就绪检查：终端仍是逐行输入（shell 未就绪）时要等", shellNotReadyWhileTerminalIsCanonical),
            Check("shell 就绪检查：行编辑器接管输入（非规范模式）后就绪", shellReadyOnceLineEditorTakesOver),
            Check("shell 就绪检查：查不到终端时不再等", shellReadinessUnknownForMissingTTY),
            Check("打开终端的 AppleScript 能通过编译（只编译，不运行）", scriptCompiles),
        ]
    }

    static let command = "'/Applications/CC Pilot.app/Contents/Resources/shell/bin/ccp' add work"

    // ---------- shell 就绪检查（ticket 22） ----------
    // 在 shell 的行编辑器（zle / readline）接管输入前就把命令送进终端，终端驱动会先回显一遍，
    // 行编辑器启动后又在提示符后显示一遍。所以要等终端进入非规范模式（-icanon）再送命令。
    // 这里用一个真实的伪终端设置不同的模式，检验就绪检查对 stty 输出的判断。

    /// 打开一个伪终端，把从端设为 canonical（逐行输入、回显）或非规范模式，返回从端路径；用完 close 两端
    static func withPTY(canonical: Bool, _ body: (String) throws -> Void) throws {
        var master: Int32 = -1, slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw CheckFailure(description: "openpty 失败：errno \(errno)")
        }
        defer { close(master); close(slave) }
        var t = termios()
        guard tcgetattr(slave, &t) == 0 else { throw CheckFailure(description: "tcgetattr 失败") }
        let lineMode = tcflag_t(ICANON) | tcflag_t(ECHO)
        if canonical { t.c_lflag |= lineMode } else { t.c_lflag &= ~lineMode }
        guard tcsetattr(slave, TCSANOW, &t) == 0 else { throw CheckFailure(description: "tcsetattr 失败") }
        guard let name = ttyname(slave) else { throw CheckFailure(description: "ttyname 失败") }
        try body(String(cString: name))
    }

    /// 运行 TerminalLauncher 的就绪检查（与 AppleScript 里 do shell script 的调用方式相同），返回它的输出
    static func readiness(of tty: String) throws -> String {
        let home = try TempHome()
        defer { home.remove() }
        let result = try ShellRun.run(home, ["/bin/sh", "-c", TerminalLauncher.shellReadyCheck, "sh", tty])
        try expectEqual(result.status, 0, "就绪检查应总是以 0 退出（AppleScript 的 do shell script 遇到非零会报错）：\(result.err)")
        return result.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shellNotReadyWhileTerminalIsCanonical() throws {
        try withPTY(canonical: true) { try expectEqual(try readiness(of: $0), "wait") }
    }

    static func shellReadyOnceLineEditorTakesOver() throws {
        try withPTY(canonical: false) { try expectEqual(try readiness(of: $0), "ready") }
    }

    static func shellReadinessUnknownForMissingTTY() throws {
        try expectEqual(try readiness(of: "/dev/ttys-no-such-tty"), "unknown")
        try expectEqual(try readiness(of: ""), "unknown")
    }

    /// 用真的 osacompile 编译脚本（只编译、不运行：不会启动"终端"，也不会发送 Apple 事件），防止语法错误
    static func scriptCompiles() throws {
        let home = try TempHome()
        defer { home.remove() }
        let out = home.root.appendingPathComponent("terminal.scpt")
        let result = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/osacompile"),
                                        TerminalLauncher.script.flatMap { ["-e", $0] } + ["-o", out.path],
                                        environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"])
        try expectEqual(result.status, 0, "osacompile 失败：\(result.stderr)")
    }

    static func opensTerminalWithCommandAsArgument() throws {
        let home = try TempHome()
        defer { home.remove() }

        let outcome = TerminalLauncher(environment: home.environment).run(command)

        try expectEqual(outcome, .opened)
        let calls = home.osascriptCalls()
        try expectEqual(calls.count, 1, "应调用一次 osascript")
        let args = calls[0]
        try expectEqual(args.last, command, "最后一个参数就是命令原文")
        try expectEqual(args.dropLast().last, TerminalLauncher.shellReadyCheck, "倒数第二个参数是 shell 就绪检查")
        let script = args.dropLast(2).joined(separator: "\n")
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
