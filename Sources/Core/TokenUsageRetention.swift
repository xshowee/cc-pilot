// 账本逐条明细的保留期（spec 决策 11）：最近 35 天，或所有档案 settings.json 里 cleanupPeriodDays
// 的最大值 + 5，取大。Claude Code 默认保留会话记录 30 天；多留几天，保证会话记录还在时明细也还在。
// projects/ 是共享资源，settings.json 每个档案一份（ADR 0003）：默认档案是 ~/.claude/settings.json，
// 其他档案是 ~/.claude-profiles/<名字>/settings.json。读不出来的文件当作没有设置。

import Foundation

enum TokenUsageRetention {
    static let minimumDays = 35
    static let marginDays = 5

    static func days(environment: CoreEnvironment) -> Int {
        let paths = ProfilePaths(environment: environment)
        let dirs = ProfileStore(environment: environment).listProfiles()
            .map(paths.runtimeDir(of:))
        let longest = dirs.compactMap { cleanupPeriodDays(in: $0 + "/settings.json") }.max() ?? 0
        return max(minimumDays, longest + marginDays)
    }

    private static func cleanupPeriodDays(in path: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return (object["cleanupPeriodDays"] as? NSNumber)?.intValue
    }
}
