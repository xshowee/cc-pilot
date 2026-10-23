// 打开 macOS 自带的"终端"（Terminal.app）执行一行命令（ticket 09：ccp add / ccp rm）。
//
// 用 osascript 让 Terminal `do script`：新开一个窗口，在用户自己的交互 shell 里执行命令，
// 所以 claude 在用户的 PATH 里就能找到；命令结束后窗口留在 shell 里，用户能看到 ccp 的输出。
// 第一次发送 Apple 事件时 macOS 会询问是否允许 CC Pilot 控制"终端"（自动化授权），
// 用户拒绝后会一直得到 -1743，App 改为给出可以复制到终端手动执行的命令。
//
// 不重复回显（ticket 22）：`do script` 是把命令当作键盘输入送进窗口的终端。新窗口里的 shell 还在启动
// （读 .zshrc 等）时，终端处于逐行输入模式，终端驱动会立刻把送进来的文字回显一遍；等 shell 的行编辑器
// （zsh 的 zle、bash 的 readline）启动，又把还没读的输入显示在提示符后，于是命令出现两遍。行编辑器
// 读输入时会把终端切到非规范模式（stty 显示 -icanon），所以先拿到要用的窗口，查它的 tty，等到
// -icanon 再送命令（最多约 10 秒；查不到就不等）。"终端"已在运行时用 `do script ""` 新开一个空窗口，
// 没在运行时用启动时自带的窗口（ticket 09：不多开空窗口），两种情况都等 shell 就绪。
//
// 命令原文作为 osascript 的参数传给脚本的 run 处理器，从不拼进脚本源码：不用处理引号，也无从注入。
// 就绪检查（shellReadyCheck）同样作为参数传入，由脚本交给 /bin/sh 执行。
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
        let result: Subprocess.Result
        do {
            result = try Subprocess.run(environment.osascript,
                                        Self.script.flatMap { ["-e", $0] } + [Self.shellReadyCheck, command],
                                        environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"])
        } catch {
            return .failed(String(describing: error))
        }
        if result.status == 0 { return .opened }
        let message = result.stderr
        if message.contains("(\(Permission.errAEEventNotPermitted))") { return .notAuthorized }
        return .failed(message.isEmpty ? "osascript exited with status \(result.status)" : message)
    }

    /// 判断某个终端（参数 $1 是 tty 路径，例如 /dev/ttys003）里的 shell 是否已经在等待输入的 /bin/sh 脚本。
    /// 输出一个词，总是以 0 退出（AppleScript 的 do shell script 遇到非零会报错）：
    ///   ready    终端处于非规范模式（-icanon）：行编辑器正在读输入，现在送命令只会显示一次
    ///   wait     仍是逐行输入模式：shell 还在启动
    ///   unknown  查不到（tty 为空、不存在或无权读取）：不再等
    /// 写成一行：作为 osascript 的一个参数传入。
    static let shellReadyCheck = #"s=$(/bin/stty -a -f "$1" 2>/dev/null) || { echo unknown; exit 0; }; "#
        + #"case " $(printf '%s' "$s" | /usr/bin/tr '\t\n' '  ') " in *' -icanon '*) echo ready ;; *) echo wait ;; esac"#

    /// AppleScript，每个元素一行（osascript -e）。argv：就绪检查、命令。
    /// "终端"没在运行时，启动它会自带一个窗口，就用那个窗口，避免多出一个空窗口；已在运行时新开一个窗口。
    /// 送命令前等窗口里的 shell 就绪（见文件开头）。do shell script 放在 tell 块之外，由 osascript 自己执行。
    static let script = [
        "on run argv",
        "set theCheck to item 1 of argv",
        "set theCommand to item 2 of argv",
        #"set wasRunning to application "Terminal" is running"#,
        #"tell application "Terminal""#,
        "set theTab to missing value",
        "if not wasRunning then",
        "activate",
        "repeat 50 times",
        "if (count of windows) > 0 then exit repeat",
        "delay 0.1",
        "end repeat",
        "if (count of windows) > 0 then set theTab to selected tab of front window",
        "end if",
        #"if theTab is missing value then set theTab to do script """#,
        #"set theTTY to """#,
        "try",
        "set theTTY to tty of theTab",
        "end try",
        "end tell",
        "waitForShell(theCheck, theTTY)",
        #"tell application "Terminal""#,
        "do script theCommand in theTab",
        "activate",
        "end tell",
        "end run",
        "on waitForShell(theCheck, theTTY)",
        "repeat 100 times",
        #"set theState to "unknown""#,
        "try",
        #"set theState to do shell script "/bin/sh -c " & quoted form of theCheck & " sh " & quoted form of theTTY"#,
        "end try",
        #"if theState is not "wait" then exit repeat"#,
        "delay 0.1",
        "end repeat",
        "end waitForShell",
    ]
}
