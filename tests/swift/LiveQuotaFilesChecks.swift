// token-usage ticket 04：实时额度的开关与文件约定（App 核心一侧）。
// 开关写在 ~/.claude-profiles/.live-quota/disabled（存在即关闭），claude 包装函数每次启动时读它；
// 这里用真实的 shell 脚本跨端验证：App 核心写、包装函数读，转发命令写、App 核心读。

import Foundation

final class LiveQuotaFilesChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("默认开启；关闭后包装函数不加状态栏覆盖，再打开又加上", toggleControlsWrapper),
            Check("关闭时档案根目录还不存在也能写；重复设置无副作用", toggleIsIdempotent),
            Check("转发命令写出的实时额度文件就在 file(for:) 指的位置", forwarderWritesWhereCoreReads),
            Check("实时额度目录不会被当成档案", liveDirectoryIsNotAProfile),
        ]
    }

    /// 在临时主目录里经包装函数启动一次假 claude，返回它收到的参数
    private static func wrapperArgs(_ home: TempHome) throws -> [String] {
        let log = home.root.appendingPathComponent("claude-log-\(UUID().uuidString)")
        let result = try ShellRun.run(home, ["/bin/zsh", "-f", "-c",
                                             "source \"$1/shell/cc-pilot.zsh\" && claude hi", "_", repoRoot.path],
                                      extraEnvironment: ["FAKE_CLAUDE_LOG_DIR": log.path])
        try expectEqual(result.status, 0, "包装函数退出码（stderr：\(result.err)）")
        let text = try String(contentsOf: log.appendingPathComponent("1"), encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            line.hasPrefix("arg=") ? String(line.dropFirst(4)) : nil
        }
    }

    static func toggleControlsWrapper() throws {
        let home = try TempHome()
        defer { home.remove() }
        let files = LiveQuotaFiles(environment: home.environment)

        try expect(files.isForwardingEnabled, "默认应开启")
        try expectEqual(try wrapperArgs(home).first, "--settings", "开启时包装函数应加 --settings")

        try files.setForwardingEnabled(false)
        try expect(!files.isForwardingEnabled, "关闭后应读到关闭")
        try expectEqual(try wrapperArgs(home), ["hi"], "关闭后包装函数不加覆盖")

        try files.setForwardingEnabled(true)
        try expect(files.isForwardingEnabled, "重新打开后应读到开启")
        try expectEqual(try wrapperArgs(home).first, "--settings", "重新打开后包装函数又加 --settings")
    }

    static func toggleIsIdempotent() throws {
        let home = try TempHome()
        defer { home.remove() }
        let files = LiveQuotaFiles(environment: home.environment)
        try files.setForwardingEnabled(true)
        try expect(!FileManager.default.fileExists(atPath: home.profilesRoot.path), "开启（默认值）不应写任何文件")
        try files.setForwardingEnabled(false)
        try files.setForwardingEnabled(false)
        try expect(!files.isForwardingEnabled, "关闭")
        try files.setForwardingEnabled(true)
        try files.setForwardingEnabled(true)
        try expect(files.isForwardingEnabled, "开启")
    }

    static func forwarderWritesWhereCoreReads() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        let status = #"{"session_id":"s-9","rate_limits":{"five_hour":{"used_percentage":40,"resets_at":1761400000}}}"#
        let result = try ShellRun.run(home, [repoRoot.appendingPathComponent("shell/bin/ccp").path,
                                             "statusline", "work"], stdin: status)
        try expectEqual(result.status, 0, "ccp statusline 退出码（stderr：\(result.err)）")
        let files = LiveQuotaFiles(environment: home.environment)
        let data = try Data(contentsOf: files.file(for: "work"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try expectEqual(object?["profile"] as? String, "work", "profile")
        try expect(object?["received_at"] is NSNumber, "received_at 应是数字")
        let inner = object?["status"] as? [String: Any]
        try expectEqual(inner?["session_id"] as? String, "s-9", "status 应是原样的状态栏 JSON")
        try expectEqual(files.file(for: "default").lastPathComponent, "default.json", "默认档案的文件名")
    }

    static func liveDirectoryIsNotAProfile() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        try LiveQuotaFiles(environment: home.environment).setForwardingEnabled(false)
        let names = ProfileStore(environment: home.environment).listProfiles().map(\.name)
        try expectEqual(names, ["default", "work"], "档案列表")
    }
}
