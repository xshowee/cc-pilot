// 实时额度（token-usage ticket 05，ADR 0004）：状态栏转发命令写下的一份实时额度文件里有用的部分。
// 文件约定见 LiveQuotaFiles。只读本地文件，不发任何网络请求。
//
// 状态栏 JSON 的 rate_limits.five_hour / seven_day 各有 used_percentage（已用百分比）和 resets_at（秒级时间戳），
// 换成与刷新结果相同的 UsageWindow（utilization = used_percentage），剩余百分比的算法因此与刷新一致。
// 并入额度显示的规则见 UsageBoard.recordLive。

import Foundation

struct LiveQuota: Equatable {
    /// 档案名（文件名去掉 .json；默认档案是 "default"）
    let profile: String
    /// 转发命令写这份文件的时间。注意它不等于数据时间：状态栏重绘时会带着旧的 rate_limits 重写文件
    let receivedAt: Date
    /// 5 小时窗口；状态栏没给（或 used_percentage 不是数字）时为 nil
    let fiveHour: UsageWindow?
    /// 覆盖全部模型的周窗口
    let sevenDay: UsageWindow?

    /// 解析一份实时额度文件；不是 JSON 对象、或 received_at 不是数字时返回 nil
    init?(profile: String, json data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let receivedAt = UsageSnapshot.number(root["received_at"]) else { return nil }
        let limits = (root["status"] as? [String: Any])?["rate_limits"] as? [String: Any]
        self.init(profile: profile, receivedAt: Date(timeIntervalSince1970: receivedAt),
                  fiveHour: Self.window(limits?["five_hour"]), sevenDay: Self.window(limits?["seven_day"]))
    }

    init(profile: String, receivedAt: Date, fiveHour: UsageWindow?, sevenDay: UsageWindow?) {
        self.profile = profile
        self.receivedAt = receivedAt
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    /// {used_percentage, resets_at}
    private static func window(_ value: Any?) -> UsageWindow? {
        guard let object = value as? [String: Any],
              let used = UsageSnapshot.number(object["used_percentage"]) else { return nil }
        return UsageWindow(utilization: used, resetsAt: UsageSnapshot.date(object["resets_at"]))
    }
}

extension LiveQuotaFiles {
    /// 读出实时额度目录里所有档案的实时额度（按档案名排序）。目录不存在时为空；
    /// 以 . 开头的文件（写入中的临时文件）、不是 .json 的文件（如开关 disabled）、读不出来的文件都跳过。
    func readAll() -> [LiveQuota] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix("."), name.hasSuffix(".json") else { return nil }
            let profile = String(name.dropLast(".json".count))
            guard ProfileName.isProfileName(profile) || profile == ProfileName.defaultName,
                  let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
            return LiveQuota(profile: profile, json: data)
        }
    }
}
