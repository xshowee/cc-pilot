// token-usage ticket 05：实时额度并入额度显示。
//
// 检查的接口（seam）：
//   LiveQuotaFiles.readAll()                 读出转发命令写下的实时额度文件
//   UsageBoard.recordLive(_:profiles:)       按档案找到账号，并入实时额度
//   UsageBoard.record(_:)                    刷新结果按同一规则并入
//   AccountUsage.fiveHour / sevenDay(now:)、fiveHourWindow、updatedAt、UsageBoard.menuBarSummary
//
// 合并规则（spec 决定 9，ticket 04 实测修订）：同一账号同一窗口，resets_at 更晚的优先；resets_at 相同时
// 取已用百分比最高的那份。变灰按这份数值最后一次被观察到（换成它，或被刷新确认）的时间算。
// 期望值都是手算的：剩余 = 100 − 已用，向下取整。

import Foundation

final class LiveQuotaMergeChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("转发命令写出的文件被读出并更新菜单栏的 5 小时剩余", forwarderFileReachesMenuBar),
            Check("读文件：跳过写入中的临时文件、开关、坏文件；状态栏没给的窗口为 nil", readAllSkipsNoise),
            Check("实时比刷新新（同一窗口已用更高）：显示实时，变灰按它的 received_at", liveNewerThanRefresh),
            Check("实时比刷新旧（同一窗口已用更低，文件却是后写的）：保留刷新，也不因重写而不变灰", liveOlderThanRefresh),
            Check("刷新在实时之后：同一规则，刷新的已用更高才采用", refreshAfterLive),
            Check("只有实时：两个主窗口都显示，按模型周窗口、超额付费没有", liveOnly),
            Check("跨窗口重置：resets_at 更晚的优先，不管哪份后到", crossWindowReset),
            Check("数值相同：刷新算确认、重新计时变灰；实时不算", confirmation),
            Check("刷新给小数、实时给整数：同一窗口取已用较高的", fractionalRefresh),
            Check("resets_at 差几秒（ISO 去掉小数秒 vs 整数秒）算同一个窗口", resetsAtTolerance),
            Check("同一账号的其他档案也显示；未登录、不在列表里的档案跳过", accountMapping),
            Check("接收实时额度不发请求，不改失败原因、频率限制和可刷新的账号", liveLeavesRefreshStateAlone),
            Check("格式无法识别：丢掉来自刷新的数字，实时额度照常显示", unrecognizedKeepsLive),
            Check("同一批文件重复并入，结果不变", idempotent),
        ]
    }

    // MARK: 准备

    /// 2027-01-15T08:00:00Z
    static let t0 = fixedNow
    static func at(minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// 构造一个已登录的档案（不碰文件）
    static func profile(_ name: String, uuid: String) -> Profile {
        Profile(name: name, configDir: "/nonexistent/\(name)", claudeJSON: URL(fileURLWithPath: "/nonexistent/\(name).json"),
                account: .loggedIn(Account(accountUuid: uuid, email: "\(name)@example.com", organizationName: nil,
                                           tier: nil)))
    }

    static let solo = profile("solo", uuid: "u-solo")
    static let soloAccount = solo.usageAccount!

    /// 一次成功的刷新（不经网络，直接构造结果）
    static func refresh(fiveHour: UsageWindow?, sevenDay: UsageWindow? = nil, at time: Date) -> UsageRefreshOutcome {
        UsageRefreshOutcome(account: soloAccount, result: .success(
            UsageSnapshot(fiveHour: fiveHour, sevenDay: sevenDay, fetchedAt: time)))
    }

    static func live(_ profile: String = "solo", fiveHour: UsageWindow?, sevenDay: UsageWindow? = nil,
                     at time: Date) -> LiveQuota {
        LiveQuota(profile: profile, receivedAt: time, fiveHour: fiveHour, sevenDay: sevenDay)
    }

    static func used(_ percent: Double, resetsInMinutes minutes: Double) -> UsageWindow {
        UsageWindow(utilization: percent, resetsAt: at(minutes: minutes))
    }

    static func fiveHour(_ board: UsageBoard, now: Date) -> UsageReading? {
        board.usage(for: solo)?.fiveHour(now: now)
    }

    static func unwrap<T>(_ value: T?, _ message: String, file: StaticString = #fileID, line: UInt = #line) throws -> T {
        guard let value else { throw CheckFailure(description: "\(file):\(line): \(message)：得到 nil") }
        return value
    }

    // MARK: 检查

    static func forwarderFileReachesMenuBar() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeProfileDir("work")
        // 5 小时窗口在 t0 + 2h 重置，已用 40%
        let resets = Int(at(minutes: 120).timeIntervalSince1970)
        let status = #"{"session_id":"s-1","rate_limits":{"five_hour":{"used_percentage":40,"resets_at":\#(resets)}}}"#
        let result = try ShellRun.run(home, [repoRoot.appendingPathComponent("shell/bin/ccp").path,
                                             "statusline", "work"], stdin: status)
        try expectEqual(result.status, 0, "ccp statusline 退出码（stderr：\(result.err)）")

        let quotas = LiveQuotaFiles(environment: home.environment).readAll()
        try expectEqual(quotas.map(\.profile), ["work"], "读出的档案")
        let quota = quotas[0]
        try expectEqual(quota.fiveHour, UsageWindow(utilization: 40, resetsAt: at(minutes: 120)), "5 小时窗口")
        try expect(quota.sevenDay == nil, "状态栏没给周窗口")
        try expect(abs(quota.receivedAt.timeIntervalSinceNow) < 60, "received_at 是写文件的时间")

        let work = profile("work", uuid: "u-work")
        var board = UsageBoard()
        board.recordLive(quotas, profiles: [work])
        let now = quota.receivedAt.addingTimeInterval(60)
        let summary = board.menuBarSummary(currentProfile: "work", profiles: [work], now: min(now, at(minutes: 119)))
        try expectEqual(summary.quotaLine(resetText: "R"), "60%", "菜单栏")
        try expectEqual(home.transport.requestCount, 0, "不发任何网络请求")
    }

    static func readAllSkipsNoise() throws {
        let home = try TempHome()
        defer { home.remove() }
        let files = LiveQuotaFiles(environment: home.environment)
        try expectEqual(files.readAll(), [], "目录不存在时为空")
        let dir = ".claude-profiles/" + LiveQuotaFiles.directoryName
        try home.write(dir + "/work.json", """
            {"profile":"work","received_at":1800000000.5,"status":{"rate_limits":{
              "five_hour":{"used_percentage":12.5,"resets_at":1800003600},
              "seven_day":{"used_percentage":70,"resets_at":1800300000}}}}
            """)
        try home.write(dir + "/default.json",
                       #"{"profile":"default","received_at":1800000100,"status":{"session_id":"s"}}"#)
        try home.write(dir + "/.work.json.123", #"{"profile":"work","received_at":1,"status":{}}"#)
        try home.write(dir + "/broken.json", "{not json")
        try home.write(dir + "/disabled", "")
        try expectEqual(files.readAll(), [
            LiveQuota(profile: "default", receivedAt: Date(timeIntervalSince1970: 1_800_000_100),
                      fiveHour: nil, sevenDay: nil),
            LiveQuota(profile: "work", receivedAt: Date(timeIntervalSince1970: 1_800_000_000.5),
                      fiveHour: UsageWindow(utilization: 12.5, resetsAt: Date(timeIntervalSince1970: 1_800_003_600)),
                      sevenDay: UsageWindow(utilization: 70, resetsAt: Date(timeIntervalSince1970: 1_800_300_000))),
        ])
    }

    static func liveNewerThanRefresh() throws {
        var board = UsageBoard()
        board.record(refresh(fiveHour: used(30, resetsInMinutes: 120), at: at(minutes: 0)))
        board.recordLive([live(fiveHour: used(45, resetsInMinutes: 120), at: at(minutes: 20))], profiles: [solo])
        try expectEqual(fiveHour(board, now: at(minutes: 25)), .remaining(55, tint: .green), "显示实时的 55%")
        // 刷新在 0 分钟，实时在 20 分钟：40 分钟时离刷新已超过 30 分钟，但离实时没有
        try expectEqual(fiveHour(board, now: at(minutes: 40)), .remaining(55, tint: .green), "按实时的时间判断变灰")
        try expectEqual(fiveHour(board, now: at(minutes: 51)), .remaining(55, tint: .stale), "实时也超过 30 分钟后变灰")
        try expectEqual(board.usage(for: solo)?.updatedAt, at(minutes: 20), "最近一次拿到数据的时间")
    }

    static func liveOlderThanRefresh() throws {
        var board = UsageBoard()
        board.record(refresh(fiveHour: used(50, resetsInMinutes: 120), at: at(minutes: 0)))
        // 另一个会话重绘状态栏，带着旧的 40% 在 20 分钟时重写了文件
        board.recordLive([live(fiveHour: used(40, resetsInMinutes: 120), at: at(minutes: 20))], profiles: [solo])
        try expectEqual(fiveHour(board, now: at(minutes: 25)), .remaining(50, tint: .yellow), "保留刷新的 50%")
        try expectEqual(fiveHour(board, now: at(minutes: 31)), .remaining(50, tint: .stale),
                        "变灰仍按刷新的时间算，旧数据重写文件不算确认")
    }

    static func refreshAfterLive() throws {
        var board = UsageBoard()
        board.recordLive([live(fiveHour: used(40, resetsInMinutes: 120), at: at(minutes: 0))], profiles: [solo])
        board.record(refresh(fiveHour: used(65, resetsInMinutes: 120), at: at(minutes: 10)))
        try expectEqual(fiveHour(board, now: at(minutes: 15)), .remaining(35, tint: .yellow), "刷新的已用更高")

        var other = UsageBoard()
        other.recordLive([live(fiveHour: used(70, resetsInMinutes: 120), at: at(minutes: 0))], profiles: [solo])
        other.record(refresh(fiveHour: used(60, resetsInMinutes: 120), at: at(minutes: 10)))
        try expectEqual(fiveHour(other, now: at(minutes: 15)), .remaining(30, tint: .yellow),
                        "刷新的已用较低：保留实时的 70%")
        try expectEqual(fiveHour(other, now: at(minutes: 31)), .remaining(30, tint: .stale), "变灰按实时的时间")
    }

    static func liveOnly() throws {
        var board = UsageBoard()
        board.recordLive([live(fiveHour: used(10, resetsInMinutes: 200), sevenDay: used(85, resetsInMinutes: 5000),
                               at: at(minutes: 0))], profiles: [solo])
        let usage = try unwrap(board.usage(for: solo), "只有实时也有额度状态")
        try expectEqual(usage.fiveHour(now: at(minutes: 1)), .remaining(90, tint: .green))
        try expectEqual(usage.sevenDay(now: at(minutes: 1)), .remaining(15, tint: .red))
        try expectEqual(usage.fiveHourWindow?.window.resetsAt, at(minutes: 200), "重置时间")
        try expectEqual(usage.modelWeekly(now: at(minutes: 1)), [], "按模型周窗口只来自刷新")
        try expect(usage.extraUsage(now: at(minutes: 1)) == nil, "超额付费只来自刷新")
        try expect(usage.snapshot == nil, "没有刷新结果")
        try expectEqual(usage.updatedAt, at(minutes: 0))
        try expectEqual(board.menuBarSummary(currentProfile: "solo", profiles: [solo], now: at(minutes: 1)).fiveHour,
                        .remaining(90, tint: .green), "菜单栏")
    }

    static func crossWindowReset() throws {
        // 刷新拿到的窗口 60 分钟时重置；之后会话里收到了下一个窗口（再 5 小时后重置），已用更低
        var board = UsageBoard()
        board.record(refresh(fiveHour: used(90, resetsInMinutes: 60), at: at(minutes: 0)))
        try expectEqual(fiveHour(board, now: at(minutes: 61)), .resetPendingRefresh, "过了重置时间")
        board.recordLive([live(fiveHour: used(5, resetsInMinutes: 60 + 300), at: at(minutes: 70))], profiles: [solo])
        try expectEqual(fiveHour(board, now: at(minutes: 71)), .remaining(95, tint: .green), "新窗口优先")

        // 反过来：已经有了新窗口，又来一份旧窗口的数据（文件更晚写，已用更高），不采用
        board.recordLive([live(fiveHour: used(90, resetsInMinutes: 60), at: at(minutes: 80))], profiles: [solo])
        try expectEqual(fiveHour(board, now: at(minutes: 81)), .remaining(95, tint: .green), "旧窗口的数据不采用")
        board.record(refresh(fiveHour: used(90, resetsInMinutes: 60), at: at(minutes: 82)))
        try expectEqual(fiveHour(board, now: at(minutes: 83)), .remaining(95, tint: .green), "刷新也同样")
    }

    static func confirmation() throws {
        var board = UsageBoard()
        board.recordLive([live(fiveHour: used(40, resetsInMinutes: 120), at: at(minutes: 0))], profiles: [solo])
        board.record(refresh(fiveHour: used(40, resetsInMinutes: 120), at: at(minutes: 20)))
        try expectEqual(fiveHour(board, now: at(minutes: 45)), .remaining(60, tint: .green), "刷新确认后从 20 分钟起算")
        try expectEqual(board.usage(for: solo)?.fiveHourWindow?.observedAt, at(minutes: 20))

        board.recordLive([live(fiveHour: used(40, resetsInMinutes: 120), at: at(minutes: 40))], profiles: [solo])
        try expectEqual(board.usage(for: solo)?.fiveHourWindow?.observedAt, at(minutes: 20), "实时的相同数值不算确认")
        try expectEqual(fiveHour(board, now: at(minutes: 51)), .remaining(60, tint: .stale))
    }

    static func fractionalRefresh() throws {
        var board = UsageBoard()
        board.record(refresh(fiveHour: used(30.4, resetsInMinutes: 120), at: at(minutes: 0)))
        board.recordLive([live(fiveHour: used(30, resetsInMinutes: 120), at: at(minutes: 10))], profiles: [solo])
        try expectEqual(board.usage(for: solo)?.fiveHourWindow?.window.utilization, 30.4, "保留刷新的 30.4")
        try expectEqual(fiveHour(board, now: at(minutes: 11)), .remaining(69, tint: .green))

        var reverse = UsageBoard()
        reverse.recordLive([live(fiveHour: used(30, resetsInMinutes: 120), at: at(minutes: 0))], profiles: [solo])
        reverse.record(refresh(fiveHour: used(30.4, resetsInMinutes: 120), at: at(minutes: 10)))
        try expectEqual(reverse.usage(for: solo)?.fiveHourWindow?.window.utilization, 30.4, "刷新的 30.4 更高")
        try expectEqual(reverse.usage(for: solo)?.fiveHourWindow?.observedAt, at(minutes: 10))
    }

    static func resetsAtTolerance() throws {
        // 刷新：2027-01-15T09:59:59.943648Z（解析时去掉小数秒）；状态栏：10:00:00 的秒时间戳，已用更低
        let body = usageJSON(fiveHour: .used(20, resetsAt: "2027-01-15T09:59:59.943648+00:00"))
        let snapshot = try unwrap(UsageSnapshot(json: Data(body.utf8), fetchedAt: at(minutes: 0)), "解析刷新结果")
        var board = UsageBoard()
        board.record(UsageRefreshOutcome(account: soloAccount, result: .success(snapshot)))
        board.recordLive([live(fiveHour: UsageWindow(utilization: 15, resetsAt: at(minutes: 120)), at: at(minutes: 10))],
                         profiles: [solo])
        try expectEqual(fiveHour(board, now: at(minutes: 11)), .remaining(80, tint: .green),
                        "同一窗口：保留已用较高的刷新，而不是把整数秒当成更晚的窗口")
    }

    static func accountMapping() throws {
        let laptop = profile("laptop", uuid: "u-solo")
        let other = profile("other", uuid: "u-other")
        let loggedOut = Profile(name: "empty", configDir: "/nonexistent/empty",
                                claudeJSON: URL(fileURLWithPath: "/nonexistent/empty.json"), account: .loggedOut)
        let profiles = [solo, laptop, other, loggedOut]
        var board = UsageBoard()
        board.recordLive([live("laptop", fiveHour: used(25, resetsInMinutes: 120), at: at(minutes: 0)),
                          live("empty", fiveHour: used(99, resetsInMinutes: 120), at: at(minutes: 0)),
                          live("gone", fiveHour: used(99, resetsInMinutes: 120), at: at(minutes: 0))],
                         profiles: profiles)
        try expectEqual(board.usage(for: solo)?.fiveHour(now: at(minutes: 1)), .remaining(75, tint: .green),
                        "laptop 的实时额度属于账号 u-solo，solo 档案也显示")
        try expectEqual(board.menuBarSummary(currentProfile: "solo", profiles: profiles, now: at(minutes: 1)).fiveHour,
                        .remaining(75, tint: .green), "菜单栏")
        try expect(board.usage(for: other) == nil, "别的账号不受影响")
        try expect(board.usage(for: loggedOut) == nil, "未登录的档案跳过")
        try expect(board.usage(for: soloAccount) == board.usage(for: laptop), "按账号查")
    }

    static func liveLeavesRefreshStateAlone() throws {
        let home = try TempHome()
        defer { home.remove() }
        var board = UsageBoard()
        let until = at(minutes: 30)
        board.record(UsageRefreshOutcome(account: soloAccount, result: .rateLimited(until: until)))
        board.recordLive([live(fiveHour: used(40, resetsInMinutes: 120), at: at(minutes: 1))], profiles: [solo])
        let usage = try unwrap(board.usage(for: solo), "有额度状态")
        try expectEqual(usage.problem, .rateLimited, "失败原因不变")
        try expectEqual(usage.retryAt, until, "频率限制等待时间不变")
        try expectEqual(board.accountsAllowedToRefresh([soloAccount], now: at(minutes: 2)), [], "仍在等待期内")
        try expectEqual(board.accountsAllowedToRefresh([soloAccount], now: at(minutes: 31)), [soloAccount],
                        "时间到了照常可以刷新")
        try expectEqual(usage.fiveHour(now: at(minutes: 2)), .remaining(60, tint: .green), "实时额度照常显示")

        var fresh = UsageBoard()
        fresh.recordLive([live(fiveHour: used(40, resetsInMinutes: 120), at: at(minutes: 1))], profiles: [solo])
        try expectEqual(fresh.usage(for: solo)?.problem, nil, "只有实时额度时没有失败原因")
        try expectEqual(fresh.accountsAllowedToRefresh([soloAccount], now: at(minutes: 2)), [soloAccount], "可以刷新")

        try home.write(".claude-profiles/" + LiveQuotaFiles.directoryName + "/solo.json",
                       #"{"received_at":1800000000,"status":{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1800009000}}}}"#)
        let quotas = LiveQuotaFiles(environment: home.environment).readAll()
        try expectEqual(quotas.count, 1, "读到文件")
        fresh.recordLive(quotas, profiles: [solo])
        try expectEqual(home.transport.requestCount, 0, "读文件、并入都不发请求")
    }

    static func unrecognizedKeepsLive() throws {
        var board = UsageBoard()
        board.record(refresh(fiveHour: used(30, resetsInMinutes: 120), sevenDay: used(50, resetsInMinutes: 5000),
                             at: at(minutes: 0)))
        board.recordLive([live(fiveHour: used(45, resetsInMinutes: 120), at: at(minutes: 5))], profiles: [solo])
        board.record(UsageRefreshOutcome(account: soloAccount, result: .unrecognizedFormat))
        let usage = try unwrap(board.usage(for: solo), "有额度状态")
        try expectEqual(usage.fiveHour(now: at(minutes: 6)), .remaining(55, tint: .green), "实时的 5 小时窗口照常")
        try expectEqual(usage.sevenDay(now: at(minutes: 6)), .unavailable, "来自刷新的周窗口显示—")

        board.recordLive([live(fiveHour: used(46, resetsInMinutes: 120), sevenDay: used(60, resetsInMinutes: 5000),
                               at: at(minutes: 7))], profiles: [solo])
        try expectEqual(board.usage(for: solo)?.sevenDay(now: at(minutes: 8)), .remaining(40, tint: .yellow),
                        "之后收到的实时周窗口照常显示")
    }

    static func idempotent() throws {
        let quotas = [live(fiveHour: used(40, resetsInMinutes: 120), sevenDay: used(10, resetsInMinutes: 5000),
                           at: at(minutes: 3))]
        var board = UsageBoard()
        board.record(refresh(fiveHour: used(40, resetsInMinutes: 120), at: at(minutes: 0)))
        board.recordLive(quotas, profiles: [solo])
        let once = board
        board.recordLive(quotas, profiles: [solo])
        board.recordLive(quotas, profiles: [solo])
        try expect(board == once, "重复并入后不变")
    }
}
