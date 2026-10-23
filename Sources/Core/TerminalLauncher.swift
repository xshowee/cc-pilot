// 打开 macOS 自带的"终端"（Terminal.app）执行一行命令（ticket 09：ccp add / ccp rm）。
//
// 用 osascript 让 Terminal `do script`：新开一个窗口，在用户自己的交互 shell 里执行命令，
// 所以 claude 在用户的 PATH 里就能找到；命令结束后窗口留在 shell 里，用户能看到 ccp 的输出。
// 第一次发送 Apple 事件时 macOS 会询问是否允许 CC Pilot 控制"终端"（自动化授权），
// 用户拒绝后会一直得到 -1743，App 改为给出可以复制到终端手动执行的命令。
//
// 命令原文作为 osascript 的参数传给脚本的 run 处理器，从不拼进脚本源码：不用处理引号，也无从注入。
// osascript 的路径来自 CoreEnvironment，测试换成假程序，绝不真的打开终端。
//
// run(_:) 会阻塞到 Terminal 接受命令为止（首次授权时要等用户在系统弹窗里作答），不要在主线程调用。

import Foundation

struct TerminalLauncher {
    enum Outcome: Equatable {
        /// 已在终端的新窗口里执行
        case opened
        /// 用户没有允许 CC Pilot 控制"终端"（系统设置 > 隐私与安全性 > 自动化）
        case notAuthorized
        /// 其他失败；附带 osascript 的说明
        case failed(String)
    }

    /// 发送 Apple 事件前查到的自动化授权状态（App 用 AEDeterminePermissionToAutomateTarget 查询，不弹窗）
    enum Permission: Equatable {
        case granted
        case denied
        /// 还没问过用户：发送时系统会弹窗询问
        case notDetermined
        /// 查不到（例如"终端"没在运行）
        case unknown

        /// 由 AEDeterminePermissionToAutomateTarget 的返回值得出
        init(status: Int32) {
            switch status {
            case 0: self = .granted
            case Self.errAEEventNotPermitted: self = .denied
            case Self.errAEEventWouldRequireUserConsent: self = .notDetermined
            default: self = .unknown
            }
        }

        /// 打开终端之前是否要先向用户说明系统会请求自动化授权。
        /// 未决定时每次都说明（系统马上会弹窗）；查不到时只在从没说明过时说明一次；
        /// 已授权不用说明；已被拒绝时说明没有用，直接给出手动执行的命令。
        func needsExplanation(explainedBefore: Bool) -> Bool {
            switch self {
            case .granted, .denied: return false
            case .notDetermined: return true
            case .unknown: return !explainedBefore
            }
        }

        static let errAEEventNotPermitted: Int32 = -1743
        static let errAEEventWouldRequireUserConsent: Int32 = -1744
    }

    /// "终端"的 bundle ID（查询授权状态用）
    static let terminalBundleID = "com.apple.Terminal"

    private let environment: CoreEnvironment

    init(environment: CoreEnvironment = .live) {
        self.environment = environment
    }

    /// 在终端的新窗口里执行 command（一行 shell 命令）。阻塞，不要在主线程调用。
    func run(_ command: String) -> Outcome {
        let process = Process()
        process.executableURL = environment.osascript
        process.arguments = Self.script.flatMap { ["-e", $0] } + [command]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        do {
            try process.run()
        } catch {
            return .failed(String(describing: error))
        }
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 0 { return .opened }
        let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if message.contains("(\(Permission.errAEEventNotPermitted))") { return .notAuthorized }
        return .failed(message.isEmpty ? "osascript exited with status \(process.terminationStatus)" : message)
    }

    /// AppleScript，每个元素一行（osascript -e）。命令从 argv 取。
    /// "终端"没在运行时，启动它会自带一个窗口，就在那个窗口里执行，避免多出一个空窗口。
    static let script = [
        "on run argv",
        "set theCommand to item 1 of argv",
        #"set wasRunning to application "Terminal" is running"#,
        #"tell application "Terminal""#,
        "if wasRunning then",
        "do script theCommand",
        "else",
        "activate",
        "repeat 50 times",
        "if (count of windows) > 0 then exit repeat",
        "delay 0.1",
        "end repeat",
        "if (count of windows) > 0 then",
        "do script theCommand in front window",
        "else",
        "do script theCommand",
        "end if",
        "end if",
        "activate",
        "end tell",
        "end run",
    ]
}
