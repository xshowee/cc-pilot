// 在检查里运行仓库 shell/ 下的真实脚本（跨端测试：App 核心写、shell 读，或反过来）。
// 与 tests/shell/lib.zsh 的 t_run 一样用干净环境：只有 HOME（临时主目录）、PATH、LANG；
// PATH 最前面是 tests/fakes/ 和一个只会失败的假 security，绝不碰真实的 claude 和钥匙串。

import Foundation

enum ShellRun {
    struct Result {
        let status: Int32
        let out: String
        let err: String
    }

    /// 运行一个程序（第一个元素是绝对路径），工作目录是临时主目录。
    /// extraEnvironment 追加进环境（例如假 claude 的 FAKE_CLAUDE_LOG_DIR）；stdin 是标准输入的内容（nil 为空）。
    static func run(_ home: TempHome, _ argv: [String], extraEnvironment: [String: String] = [:],
                    stdin: String? = nil) throws -> Result {
        let fakeBin = home.root.appendingPathComponent("fake-bin")
        let security = fakeBin.appendingPathComponent("security")
        if !FileManager.default.fileExists(atPath: security.path) {
            try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
            try Data("#!/bin/sh\necho 'fake security: not available in checks' >&2\nexit 44\n".utf8)
                .write(to: security)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: security.path)
        }
        let fakes = repoRoot.appendingPathComponent("tests/fakes").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = [
            "HOME": home.url.path,
            "PATH": "\(fakes):\(fakeBin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
        ].merging(extraEnvironment) { _, extra in extra }
        process.currentDirectoryURL = home.url
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        }
        // 输出很短（一两行），先读 stdout 再读 stderr 不会因管道写满而互相卡住
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }

    /// 在新的 `zsh -f` 里执行一段代码，参数依次是 $1 $2 …
    static func zsh(_ home: TempHome, _ code: String, _ args: String...) throws -> Result {
        try run(home, ["/bin/zsh", "-f", "-c", code, "_"] + args)
    }
}
