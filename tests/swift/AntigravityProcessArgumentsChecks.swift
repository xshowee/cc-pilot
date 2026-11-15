// 找 Antigravity language server 时的纯逻辑（AntigravityProcessArguments）：哪个可执行文件算数、
// KERN_PROCARGS2 怎么拆成参数、从参数里取 csrf token。只用手写的字符串和字节，绝不读取真实进程。
// 参数取自 2026-11-14 实测的启动参数（token 换成假的）：--csrf_token 用空格写法，--host_bridge_* 用等号写法。

import Foundation

final class AntigravityProcessArgumentsChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("只认 Antigravity.app 包内名为 language_server 的可执行文件，不写死 /Applications", executables),
            Check("KERN_PROCARGS2：跳过可执行文件路径和补齐的 NUL，取 argc 个参数，不读环境变量", procArgs),
            Check("csrf token：空格、等号两种写法都认；不取 host_bridge_token；缺值时没有", csrfToken),
        ]
    }

    static let path = "/Applications/Antigravity.app/Contents/Resources/bin/language_server"

    /// 实测的启动参数（token 是假的）
    static let realArguments = [
        path, "--standalone", "--override_ide_name", "antigravity", "--subclient_type", "hub",
        "--override_ide_version", "2.32.1", "--override_user_agent_name", "antigravity", "--https_server_port", "0",
        "--csrf_token", "FAKE-csrf-1234", "--app_data_dir", "antigravity", "--enable_sidecars",
        "--host_bridge_url=http://127.0.0.1:61881", "--host_bridge_token=FAKE-bridge-5678",
    ]

    static func executables() throws {
        for good in [path, "/Users/tester/Applications/Antigravity.app/Contents/Resources/bin/language_server",
                     "/Volumes/X/Antigravity.app/Contents/Resources/bin/language_server"] {
            try expect(AntigravityProcessArguments.isLanguageServer(executablePath: good), good)
        }
        for bad in ["/usr/local/bin/language_server", "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
                    "/Applications/Windsurf.app/Contents/Resources/bin/language_server",
                    "/Applications/Antigravity IDE.app/Contents/Resources/bin/language_server",
                    "/Applications/Antigravity.app/Contents/Resources/bin/language_server_helper",
                    "/tmp/Antigravity.app.bak/language_server", ""] {
            try expect(!AntigravityProcessArguments.isLanguageServer(executablePath: bad), bad)
        }
    }

    /// 按 KERN_PROCARGS2 的布局拼字节：argc（小端 int32）、可执行文件路径、补齐的 NUL、参数、环境变量
    static func procArgsBytes(argc: Int32, path: String, arguments: [String], environment: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
        bytes += Array(path.utf8) + [0, 0, 0, 0]
        for item in arguments + environment { bytes += Array(item.utf8) + [0] }
        return bytes
    }

    static func procArgs() throws {
        let bytes = procArgsBytes(argc: Int32(realArguments.count), path: path, arguments: realArguments,
                                  environment: ["HOME=/Users/tester", "ANTIGRAVITY_CSRF_TOKEN=from-env"])
        try expectEqual(AntigravityProcessArguments.arguments(fromProcArgs: bytes), realArguments)

        let truncated = procArgsBytes(argc: 5, path: path, arguments: [path, "--csrf_token"], environment: [])
        try expectEqual(AntigravityProcessArguments.arguments(fromProcArgs: truncated), nil, "参数不够 argc 个")
        try expectEqual(AntigravityProcessArguments.arguments(fromProcArgs: [1, 0]), nil, "太短")
    }

    static func csrfToken() throws {
        func token(_ arguments: [String]) -> String? { AntigravityProcessArguments.csrfToken(in: arguments) }
        try expectEqual(token(realArguments), "FAKE-csrf-1234", "空格写法")
        try expectEqual(token([path, "--csrf_token=FAKE-eq"]), "FAKE-eq", "等号写法")
        try expectEqual(token([path, "--host_bridge_token=FAKE-bridge-5678"]), nil, "host_bridge_token 不是要的 token")
        try expectEqual(token([path, "--host_bridge_token", "x", "--csrf_tokenX", "y"]), nil, "名字要完全相同")
        try expectEqual(token([path]), nil, "没有这个参数")
        try expectEqual(token([path, "--csrf_token"]), nil, "在最后、没有值")
        try expectEqual(token([path, "--csrf_token", "--app_data_dir", "antigravity"]), nil, "后面紧跟别的参数")
        try expectEqual(token([path, "--csrf_token="]), nil, "等号后为空")
    }
}
