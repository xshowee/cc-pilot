// 找 Antigravity language server 时的纯逻辑（AntigravityProcessArguments、AntigravityHubDaemon）：
// 哪个可执行文件算数、KERN_PROCARGS2 怎么拆成参数、从守护文件或参数里取 csrf token、合并端口、
// 以及 CoreEnvironment(home:) 接线。只用假数据和 TempHome，绝不读取真实进程或真实 ~/.gemini。
// 参数取自 2026-11-14 实测的启动参数（token 换成假的）：--csrf_token 用空格写法，--host_bridge_* 用等号写法。

import Foundation

final class AntigravityProcessArgumentsChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("只认 Antigravity.app 包内名为 language_server 的可执行文件，不写死 /Applications", executables),
            Check("KERN_PROCARGS2：跳过可执行文件路径和补齐的 NUL，取 argc 个参数，不读环境变量", procArgs),
            Check("csrf token：空格、等号两种写法都认；不取 host_bridge_token；缺值时没有", csrfToken),
            Check("hub_*.json 文件名匹配：大小写不敏感，拒绝无关或临时文件名", hubFileNames),
            Check("hub_*.json 解析：支持 2.34.0 格式与回退键名，忽略 httpsPort，拒绝非法类型或数值", hubJsonParsing),
            Check("hub_*.json 目录扫描：按 pid 过滤、忽略子目录与坏文件、按修改时间优先并回退旧有效文件", hubDirectoryScan),
            Check("resolveCsrfToken 与 mergedPorts：守护文件优先、缺时回退 KERN_PROCARGS2 并合并去重端口", resolveAndMergePorts),
            Check("CoreEnvironment(home:) 自动将 LiveAntigravityProcessQuery 指向该 home 的 daemon 目录", coreEnvironmentWiring),
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

    static func hubFileNames() throws {
        for good in ["hub_58893.json", "HUB_123.JSON", "hub_.json"] {
            try expect(AntigravityHubDaemon.isHubFileName(good), good)
        }
        for bad in ["other.json", "hub_58893.json.tmp", "my_hub_58893.json", "hub_58893.txt", ""] {
            try expect(!AntigravityHubDaemon.isHubFileName(bad), bad)
        }
    }

    static func hubJsonParsing() throws {
        func parse(_ json: String) -> AntigravityHubDaemon.Record? {
            AntigravityHubDaemon.parse(data: Data(json.utf8))
        }

        try expectEqual(
            parse(#"{"pid":84815,"httpPort":58893,"httpsPort":58892,"csrfToken":"FAKE-csrf-234","lsVersion":"2.34.0"}"#),
            AntigravityHubDaemon.Record(pid: 84815, csrfToken: "FAKE-csrf-234", httpPort: 58893),
            "2.34.0 真实格式"
        )
        try expectEqual(
            parse(#"{"pid":84815,"httpsPort":58892,"csrfToken":"FAKE-csrf-234"}"#),
            AntigravityHubDaemon.Record(pid: 84815, csrfToken: "FAKE-csrf-234", httpPort: nil),
            "只有 httpsPort 时不取端口"
        )
        try expectEqual(
            parse(#"{"pid":84815,"port":58890,"csrf_token":"FAKE-snake"}"#),
            AntigravityHubDaemon.Record(pid: 84815, csrfToken: "FAKE-snake", httpPort: 58890),
            "兼容 csrf_token 与 port"
        )
        try expectEqual(
            parse(#"{"pid":84815,"httpPort":58893,"port":58890,"csrfToken":"FAKE-camel","csrf_token":"FAKE-snake"}"#),
            AntigravityHubDaemon.Record(pid: 84815, csrfToken: "FAKE-camel", httpPort: 58893),
            "同时存在时优先 csrfToken 与 httpPort"
        )
        try expectEqual(
            parse(#"{"pid":84815,"csrfToken":"  FAKE-trimmed \n"}"#),
            AntigravityHubDaemon.Record(pid: 84815, csrfToken: "FAKE-trimmed", httpPort: nil),
            "csrfToken 去除首尾空白"
        )
        try expectEqual(
            parse(#"{"pid":84815,"csrfToken":"   \t "}"#),
            AntigravityHubDaemon.Record(pid: 84815, csrfToken: nil, httpPort: nil),
            "纯空白 csrfToken 当作缺失"
        )
        try expectEqual(
            parse(#"{"pid":84815,"csrfToken":""}"#),
            AntigravityHubDaemon.Record(pid: 84815, csrfToken: nil, httpPort: nil),
            "空字符串 csrfToken 当作缺失"
        )

        for badPID in [
            #"{}"#,
            #"{"pid":0,"csrfToken":"FAKE"}"#,
            #"{"pid":-1,"csrfToken":"FAKE"}"#,
            #"{"pid":true,"csrfToken":"FAKE"}"#,
            #"{"pid":1.5,"csrfToken":"FAKE"}"#,
            #"{"pid":"84815","csrfToken":"FAKE"}"#,
            "not json",
            "[]",
            #""x""#,
        ] {
            try expectEqual(parse(badPID), nil, "非法 pid 或 JSON：\(badPID)")
        }

        for badPort in ["0", "-1", "65536", "true", "80.5", #""58893""#] {
            let json = #"{"pid":84815,"httpPort":\#(badPort),"csrfToken":"FAKE-tok"}"#
            try expectEqual(
                parse(json),
                AntigravityHubDaemon.Record(pid: 84815, csrfToken: "FAKE-tok", httpPort: nil),
                "非法 httpPort：\(badPort)"
            )
        }
    }

    static func hubDirectoryScan() throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemonDir = AntigravityHubDaemon.daemonDirectory(in: home.url)
        let fm = FileManager.default

        try expectEqual(AntigravityHubDaemon.records(forPID: 84815, in: daemonDir), [], "目录不存在时为空")
        try expectEqual(AntigravityHubDaemon.csrfToken(forPID: 84815, in: daemonDir), nil, "目录不存在时无 token")

        // 准备无关文件、同名子目录、坏文件与其他 pid 文件
        try home.write(".gemini/antigravity/daemon/other.json", #"{"pid":84815,"httpPort":50001,"csrfToken":"WRONG-name"}"#)
        try home.write(".gemini/antigravity/daemon/hub_bad.json", "{broken json")
        try home.write(".gemini/antigravity/daemon/hub_other.json", #"{"pid":99999,"httpPort":50002,"csrfToken":"OTHER-pid"}"#)
        try fm.createDirectory(at: daemonDir.appendingPathComponent("hub_dir.json"), withIntermediateDirectories: true)

        // 同一 pid 的多个文件：旧文件有完整 token，新文件先设成也有 token 验证按修改时间降序
        try home.write(".gemini/antigravity/daemon/hub_old.json", #"{"pid":84815,"httpPort":58891,"csrfToken":"FAKE-old"}"#)
        try home.write(".gemini/antigravity/daemon/hub_new.json", #"{"pid":84815,"httpPort":58893,"csrfToken":"FAKE-new"}"#)
        let oldURL = daemonDir.appendingPathComponent("hub_old.json")
        let newURL = daemonDir.appendingPathComponent("hub_new.json")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)], ofItemAtPath: oldURL.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_200)], ofItemAtPath: newURL.path)

        try expectEqual(AntigravityHubDaemon.csrfToken(forPID: 84815, in: daemonDir), "FAKE-new", "最新文件优先")
        try expectEqual(
            AntigravityHubDaemon.records(forPID: 84815, in: daemonDir).map(\.httpPort),
            [58893, 58891],
            "按修改时间降序排列"
        )

        // 最新文件缺少 csrfToken 时，自动回退到同 pid 较旧的有效文件
        try home.write(".gemini/antigravity/daemon/hub_new.json", #"{"pid":84815,"httpPort":58893}"#)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_300)], ofItemAtPath: newURL.path)
        try expectEqual(AntigravityHubDaemon.csrfToken(forPID: 84815, in: daemonDir), "FAKE-old", "最新缺 token 时回退旧有效文件")

        // 最新文件损坏时，同样回退到较旧有效文件
        try home.write(".gemini/antigravity/daemon/hub_new.json", "not-json")
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_400)], ofItemAtPath: newURL.path)
        try expectEqual(AntigravityHubDaemon.csrfToken(forPID: 84815, in: daemonDir), "FAKE-old", "最新损坏时回退旧有效文件")
    }

    static func resolveAndMergePorts() throws {
        let home = try TempHome()
        defer { home.remove() }
        let daemonDir = AntigravityHubDaemon.daemonDirectory(in: home.url)
        let procBytes = procArgsBytes(
            argc: Int32(realArguments.count),
            path: path,
            arguments: realArguments,
            environment: []
        )
        let noTokenArgs = [path, "--standalone", "--https_server_port", "0"]
        let noTokenBytes = procArgsBytes(argc: Int32(noTokenArgs.count), path: path, arguments: noTokenArgs, environment: [])

        // 1. 无守护文件时回退到 KERN_PROCARGS2
        var fallbackCalls = 0
        let fromProc = AntigravityProcessArguments.resolveCsrfToken(pid: 84815, daemonDirectory: daemonDir) {
            fallbackCalls += 1
            return procBytes
        }
        try expectEqual(fromProc, "FAKE-csrf-1234", "无守护文件时回退命令行参数")
        try expectEqual(fallbackCalls, 1)
        try expectEqual(
            AntigravityHubDaemon.mergedPorts(forPID: 84815, in: daemonDir, socketPorts: [0, 58892, 70000, 58893, 58892]),
            [58892, 58893],
            "无守护文件时返回合法且去重的套接字端口"
        )

        // 2. 有其他 pid 的守护文件或当前 pid 缺 token 的守护文件时仍回退 KERN_PROCARGS2
        try home.write(".gemini/antigravity/daemon/hub_58893.json", #"{"pid":99999,"httpPort":58893,"csrfToken":"FAKE-other"}"#)
        try home.write(".gemini/antigravity/daemon/hub_58894.json", #"{"pid":84815,"httpPort":58894}"#)
        let fallbackOnMissingToken = AntigravityProcessArguments.resolveCsrfToken(pid: 84815, daemonDirectory: daemonDir) {
            fallbackCalls += 1
            return procBytes
        }
        try expectEqual(fallbackOnMissingToken, "FAKE-csrf-1234", "守护文件无 token 时回退命令行参数")
        try expectEqual(fallbackCalls, 2)

        // 3. 守护文件与 procArgs 都无 token 时返回 nil
        let missingBoth = AntigravityProcessArguments.resolveCsrfToken(pid: 84815, daemonDirectory: daemonDir) {
            fallbackCalls += 1
            return noTokenBytes
        }
        try expectEqual(missingBoth, nil, "两边都无 token")
        try expectEqual(fallbackCalls, 3)

        // 4. 命中当前 pid 有效守护文件时直接返回且不调用 procArgs 回调
        let hub58894 = daemonDir.appendingPathComponent("hub_58894.json")
        let hub58893 = daemonDir.appendingPathComponent("hub_58893.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)], ofItemAtPath: hub58894.path)
        try home.write(".gemini/antigravity/daemon/hub_58893.json", #"{"pid":84815,"httpPort":58893,"httpsPort":58892,"csrfToken":"FAKE-daemon"}"#)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_200)], ofItemAtPath: hub58893.path)
        let fromDaemon = AntigravityProcessArguments.resolveCsrfToken(pid: 84815, daemonDirectory: daemonDir) {
            fallbackCalls += 1
            return procBytes
        }
        try expectEqual(fromDaemon, "FAKE-daemon", "优先使用守护文件 token")
        try expectEqual(fallbackCalls, 3, "命中守护文件时不读取 procArgs")

        try expectEqual(
            AntigravityHubDaemon.mergedPorts(forPID: 84815, in: daemonDir, socketPorts: [58892, 58893, 52243]),
            [58893, 58894, 58892, 52243],
            "守护文件 httpPort 排在套接字端口之前并去重"
        )
        try expectEqual(
            AntigravityHubDaemon.mergedPorts(forPID: 84815, in: daemonDir, socketPorts: []),
            [58893, 58894],
            "套接字端口为空时仍返回守护文件端口"
        )
    }

    static func coreEnvironmentWiring() throws {
        let home = try TempHome()
        defer { home.remove() }
        let env = CoreEnvironment(home: home.url)
        let query = env.antigravityProcesses as? LiveAntigravityProcessQuery
        try expectEqual(
            query?.daemonDirectory,
            AntigravityHubDaemon.daemonDirectory(in: home.url),
            "CoreEnvironment(home:) 应绑定到对应 home 的 daemon 目录"
        )
    }
}
