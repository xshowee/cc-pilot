// 运行一个外部程序直到它退出（TerminalLauncher 调 osascript、ShellIntegration 调 ccp 共用）。
// 标准输入为空（不会卡在询问上），标准输出丢弃，只收集标准错误作为失败时的说明。
// 阻塞调用线程，不要在主线程调用。读取凭据的 security 另有超时处理，见 CredentialReader。

import Foundation

enum Subprocess {
    struct Result {
        let status: Int32
        /// 标准错误的内容，去掉首尾空白
        let stderr: String
    }

    /// 启动失败（例如程序不存在）时抛错；程序以非零状态退出不算错误，由调用方看 status
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                    currentDirectory: URL? = nil) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        try process.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
