// Antigravity 看板（AntigravityBoard / AntigravityBoardStore，spec "快照与看板""刷新"，接缝 2）。
// 只看外部行为：把刷新结果交给 record(_:clicked:)，看 cards(now:) 算出的卡片、返回的短暂提示；
// 持久化用 TempHome（写入后新建看板读回、删除后读不回、文件损坏当作没有快照）。
// 不碰进程、不联网。期望值都是手算的：剩余 = 100 − 已用，向下取整。

import Foundation

final class AntigravityBoardChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("添加：去掉首尾空白；空、不像邮箱、已添加（不分大小写）不能添加；卡片排在最后、还没读到过", addEmails),
            Check("成功读到已添加的邮箱：套餐、组、桶按刷新结果，最后读到的卡片正常显示，需要写回", addedEmailRead),
            Check("成功读到没添加的邮箱：不建卡片、不存数据，记为最后读到（已添加的都变灰），清掉不知道账号时的原因", unaddedEmailRead),
            Check("已添加的邮箱不分大小写：刷新结果、被点卡片、删除；卡片保持添加时的写法", caseInsensitive),
            Check("同一邮箱再次成功：直接替换旧快照（剩余回升也照用，不合并），卡片不换位置", sameEmailReplaces),
            Check("最后读到的正常，其他整体变灰并带读取时间（不到 30 分钟也变灰）", oldSnapshotsGray),
            Check("快照里过了重置时间的窗口：已重置，待刷新；没有数字的窗口：—", resetAndMissing),
            Check("同组同一窗口类型出现多次：第二个起带区分标签（桶名，没有时 bucketId），第一个没有", repeatedWindowLabels),
            Check("同组内 5 小时窗口排在周窗口前（各自保持接口顺序），区分标签规则不变；组顺序不变", windowOrder),
            Check("格式无法识别带邮箱：丢掉这个邮箱的快照数据，卡片留着显示接口可能已变化，需要写回", unrecognizedWithEmail),
            Check("格式无法识别没有邮箱：不丢任何快照，只在被点的卡片（刷新全部时最后读到的）显示", unrecognizedWithoutEmail),
            Check("失败：保留快照记原因；落在读到的邮箱，没有邮箱时落在被点的卡片，刷新全部时落在最后读到的", failures),
            Check("未登录：原因落在被点的卡片（刷新全部时最后读到的）", notSignedIn),
            Check("App 没开：什么都不改；被点的卡片得到短暂提示，刷新全部时没有提示", appNotRunning),
            Check("读到的邮箱与被点卡片不同：被点卡片得到短暂提示\"登录的是 <邮箱>\"（失败、格式无法识别时也给）", signedInAsNotice),
            Check("读到没添加的邮箱时失败：不建卡片，原因落在被点的卡片", failureForUnknownEmail),
            Check("读取进行中再点别的卡片：不发起新的读取、也转圈；结束后每张被点的卡片各自得到提示", joinedClicks),
            Check("不知道账号时落下的原因（未登录等）：之后任一邮箱成功时清掉；有账号的原因只由这个邮箱的成功清掉", accountlessProblemsClear),
            Check("删除：卡片消失；删的是最后读到的，其余都是旧快照；之后再读到同一邮箱不重新出现，要再手动添加", remove),
            Check("持久化：写入后新建看板能读回（读取时间含小数秒、各组各桶、最后读到），文件在账本同一目录", persistRoundTrip),
            Check("持久化：删除后读不回；没有文件时是空看板；失败原因不存", persistRemoval),
            Check("格式无法识别后没有数据的卡片：重启后仍在，一直显示接口可能已变化，直到这个邮箱下次成功", persistDataless),
            Check("持久化：能读旧的版本 1 文件，写回时用版本 3", persistReadsVersion1),
            Check("持久化：能读版本 2 文件（账号都当作已添加，没有数据的是格式无法识别），写回时用版本 3", persistReadsVersion2),
            Check("持久化：版本 3 区分还没读到过与格式无法识别，重启后照样显示", persistNotReadYet),
            Check("持久化：文件损坏、格式不对时当作没有快照，不报错；存的内容不含 csrf token", persistCorrupt),
        ]
    }

    static let now = fixedNow
    static func at(minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    static let ultra = "ultra@example.com"
    static let pro = "pro@example.com"

    /// 一个桶：剩余 remaining%（nil 表示没有数字），resetIn 分钟后重置
    static func bucket(_ id: String, _ window: AntigravityQuotaBucket.Window, remaining: Double?,
                       resetIn minutes: Double? = 120, name: String? = nil) -> AntigravityQuotaBucket {
        AntigravityQuotaBucket(bucketId: id, displayName: name, window: window,
                               usage: remaining.map { UsageWindow(utilization: 100 - $0,
                                                                  resetsAt: minutes.map(at(minutes:))) })
    }

    /// Ultra 形态：两组，各一个周窗口、一个 5 小时窗口（周窗口在前，同接口顺序）
    static func ultraQuota(email: String = ultra, gemini5h: Double = 71.12, fetchedAt: Date = fixedNow)
        -> AntigravityAccountQuota {
        AntigravityAccountQuota(
            email: email, tierName: "Google AI Ultra", tierId: "g1-ultra-lite-tier",
            groups: [
                AntigravityQuotaGroup(kind: .gemini, displayName: "Gemini Models", models: ["Gemini 3 Pro", "Gemini 3 Flash"],
                                      buckets: [bucket("gemini-weekly", .weekly, remaining: 92.86, resetIn: 3 * 1440),
                                                bucket("gemini-5h", .fiveHour, remaining: gemini5h, resetIn: 133)]),
                AntigravityQuotaGroup(kind: .thirdParty, displayName: "Claude and GPT models", models: ["Claude Opus 4.5"],
                                      buckets: [bucket("3p-weekly", .weekly, remaining: 40, resetIn: 2 * 1440),
                                                bucket("3p-5h", .fiveHour, remaining: 15, resetIn: 60)]),
            ],
            fetchedAt: fetchedAt)
    }

    /// Pro 形态：一组，只有一个周窗口
    static func proQuota(fetchedAt: Date = fixedNow) -> AntigravityAccountQuota {
        AntigravityAccountQuota(
            email: pro, tierName: "Google AI Pro", tierId: "g1-pro-tier",
            groups: [AntigravityQuotaGroup(kind: .other, displayName: "Gemini 4 Argon", models: [],
                                           buckets: [bucket("argon-weekly", .weekly, remaining: 64, resetIn: 1440)])],
            fetchedAt: fetchedAt)
    }

    /// 卡片里各桶的 (bucketId, 显示)
    static func readings(_ card: AntigravityCard) -> [[String?: UsageReading]] {
        card.groups.map { group in
            Dictionary(uniqueKeysWithValues: group.buckets.map { ($0.bucketId, $0.reading) })
        }
    }

    /// 依次添加这些邮箱的看板（还没读到过）
    static func added(_ emails: String...) -> AntigravityBoard {
        var board = AntigravityBoard()
        for email in emails { board.add(email) }
        return board
    }

    // MARK: - 添加

    static func addEmails() throws {
        var board = AntigravityBoard()
        try expectEqual(board.problem(forNewEmail: ""), .empty)
        try expectEqual(board.problem(forNewEmail: " \n"), .empty)
        for text in ["ultra", "@example.com", "ultra@", " @ ", "ul tra@example.com", "ultra@exa\tmple.com",
                     "ultra@example.com\nx"] {
            try expectEqual(board.problem(forNewEmail: text), .malformed, "输入：\(text)")
        }
        try expectEqual(board.problem(forNewEmail: " ultra@example.com\n"), nil)

        try expectEqual(board.add(" ultra@example.com\n"), true)
        try expectEqual(board.add(pro), true)
        try expectEqual(board.emails, [ultra, pro], "去掉首尾空白，按添加顺序")

        // 已添加：不分大小写，去掉空白后比较
        try expectEqual(board.problem(forNewEmail: " ULTRA@Example.com "), .exists)
        let before = board
        for text in ["Ultra@Example.com", "", "ultra"] {
            try expectEqual(board.add(text), false, "输入：\(text)")
        }
        try expectEqual(board, before)

        // 还没读到过：没有问题、没有组、没有读取时间、没有套餐
        let cards = board.cards(now: now)
        try expectEqual(cards.map(\.isNotReadYet), [true, true])
        try expectEqual(cards.map(\.problem), [nil, nil])
        try expectEqual(cards.map(\.groups), [[], []])
        try expectEqual(cards.map(\.fetchedAt), [nil, nil])
        try expectEqual(cards.map(\.tierName), [nil, nil])
        try expectEqual(cards.map(\.isOldSnapshot), [true, true])

        // 读到它之后加在后面的卡片仍排在最后
        board.record(.success(proQuota()), clicked: pro)
        board.add("third@example.com")
        try expectEqual(board.emails, [ultra, pro, "third@example.com"])
        try expectEqual(board.cards(now: now).map(\.isNotReadYet), [true, false, true])
    }

    // MARK: - 刷新结果并入

    static func addedEmailRead() throws {
        var board = added(ultra)
        try expectEqual(board.cards(now: now).map(\.isNotReadYet), [true])

        let effect = board.record(.success(ultraQuota()), clicked: nil)
        try expectEqual(effect, AntigravityRecordEffect(notices: [], needsSave: true))

        let cards = board.cards(now: at(minutes: 5))
        try expectEqual(cards.map(\.email), [ultra])
        let card = cards[0]
        try expectEqual(card.tierName, "Google AI Ultra")
        try expectEqual(card.isOldSnapshot, false)
        try expectEqual(card.isNotReadYet, false)
        try expectEqual(card.fetchedAt, now)
        try expectEqual(card.problem, nil)
        try expectEqual(card.groups.map(\.kind), [.gemini, .thirdParty])
        try expectEqual(card.groups.map(\.displayName), ["Gemini Models", "Claude and GPT models"])
        try expectEqual(card.groups[0].models, ["Gemini 3 Pro", "Gemini 3 Flash"])
        // 接口给的是周窗口在前；卡片同 Claude Code、Kimi Code，5 小时窗口在前
        try expectEqual(card.groups[0].buckets.map(\.window), [.fiveHour, .weekly])
        try expectEqual(card.groups[0].buckets.map(\.bucketId), ["gemini-5h", "gemini-weekly"])
        // 92.86 → 92 绿；71.12 → 71 绿；40 → 黄；15 → 红
        try expectEqual(readings(card), [
            ["gemini-weekly": .remaining(92, tint: .green), "gemini-5h": .remaining(71, tint: .green)],
            ["3p-weekly": .remaining(40, tint: .yellow), "3p-5h": .remaining(15, tint: .red)],
        ])
        try expectEqual(card.groups[0].buckets[0].resetsAt, at(minutes: 133))
    }

    static func sameEmailReplaces() throws {
        var board = added(ultra, pro)
        board.record(.success(ultraQuota(gemini5h: 10)), clicked: nil)
        board.record(.success(proQuota()), clicked: nil)
        // 5 小时窗口滚动后剩余回升：直接用新数字（合并规则会停在旧的较低数字上）
        let effect = board.record(.success(ultraQuota(gemini5h: 80.5, fetchedAt: at(minutes: 10))), clicked: ultra)
        try expectEqual(effect, AntigravityRecordEffect(notices: [], needsSave: true))
        let cards = board.cards(now: at(minutes: 11))
        try expectEqual(cards.map(\.email), [ultra, pro])
        try expectEqual(cards[0].fetchedAt, at(minutes: 10))
        try expectEqual(cards[0].groups[0].buckets[0].reading, .remaining(80, tint: .green))

        // 新快照只有一组：旧快照的组不留下
        let single = AntigravityAccountQuota(email: ultra, tierName: nil, tierId: nil,
                                             groups: [proQuota().groups[0]], fetchedAt: at(minutes: 20))
        board.record(.success(single), clicked: nil)
        let replaced = board.cards(now: at(minutes: 21))[0]
        try expectEqual(replaced.groups.map(\.displayName), ["Gemini 4 Argon"])
        try expectEqual(replaced.tierName, nil)
    }

    static func oldSnapshotsGray() throws {
        var board = added(ultra, pro)
        board.record(.success(ultraQuota()), clicked: nil)
        board.record(.success(proQuota(fetchedAt: at(minutes: 3))), clicked: nil)
        try expectEqual(board.lastReadEmail, pro)

        // 5 分钟：ultra 的快照才 5 分钟，但已不是最后读到的 → 整体变灰，数字照常
        let cards = board.cards(now: at(minutes: 5))
        try expectEqual(cards.map(\.isOldSnapshot), [true, false])
        try expectEqual(cards[0].fetchedAt, now)
        try expectEqual(readings(cards[0]), [
            ["gemini-weekly": .remaining(92, tint: .stale), "gemini-5h": .remaining(71, tint: .stale)],
            ["3p-weekly": .remaining(40, tint: .stale), "3p-5h": .remaining(15, tint: .stale)],
        ])
        try expectEqual(readings(cards[1]), [["argon-weekly": .remaining(64, tint: .green)]])

        // 最后读到的超过 30 分钟：同 UsageReading，也变灰，但不算旧快照
        let later = board.cards(now: at(minutes: 40))
        try expectEqual(later[1].isOldSnapshot, false)
        try expectEqual(readings(later[1]), [["argon-weekly": .remaining(64, tint: .stale)]])
    }

    static func resetAndMissing() throws {
        var board = added(ultra, pro)
        var quota = ultraQuota()
        quota = AntigravityAccountQuota(
            email: quota.email, tierName: quota.tierName, tierId: quota.tierId,
            groups: quota.groups + [AntigravityQuotaGroup(kind: .other, displayName: "Empty", models: [],
                                                          buckets: [bucket("empty-5h", .fiveHour, remaining: nil)])],
            fetchedAt: quota.fetchedAt)
        board.record(.success(quota), clicked: nil)
        board.record(.success(proQuota()), clicked: nil)

        // 61 分钟后：3p-5h（60 分钟后重置）已重置，旧快照里也显示已重置，不显示灰的旧数字
        let card = board.cards(now: at(minutes: 61))[0]
        try expectEqual(card.isOldSnapshot, true)
        try expectEqual(readings(card), [
            ["gemini-weekly": .remaining(92, tint: .stale), "gemini-5h": .remaining(71, tint: .stale)],
            ["3p-weekly": .remaining(40, tint: .stale), "3p-5h": .resetPendingRefresh],
            ["empty-5h": .unavailable],
        ])
        try expectEqual(card.groups[2].buckets[0].resetsAt, nil)

        // 最后读到的卡片同样按重置时间：1441 分钟后 argon-weekly 已重置
        try expectEqual(readings(board.cards(now: at(minutes: 1441))[1]), [["argon-weekly": .resetPendingRefresh]])
    }

    static func repeatedWindowLabels() throws {
        // Pro 形态 2：Gemini 组里 5h、weekly、argon weekly；再加一个没有桶名的 weekly、一个什么都没有的 weekly
        let quota = AntigravityAccountQuota(
            email: pro, tierName: "Google AI Pro", tierId: "g1-pro-tier",
            groups: [
                AntigravityQuotaGroup(kind: .gemini, displayName: "Gemini Models", models: [],
                                      buckets: [bucket("gemini-5h", .fiveHour, remaining: 50, name: "5h Limit"),
                                                bucket("gemini-weekly", .weekly, remaining: 60, name: "Weekly Limit"),
                                                bucket("argon-weekly", .weekly, remaining: 70, name: "Argon Weekly Limit"),
                                                bucket("carbon-weekly", .weekly, remaining: 80),
                                                AntigravityQuotaBucket(bucketId: nil, displayName: nil, window: .weekly,
                                                                       usage: nil)]),
                // 别的组里的周窗口不算重复
                AntigravityQuotaGroup(kind: .other, displayName: "Gemini 4 Argon", models: [],
                                      buckets: [bucket("gemini-argon-wtu-weekly", .weekly, remaining: 10, name: "Argon")]),
            ],
            fetchedAt: now)
        var board = added(pro)
        board.record(.success(quota), clicked: nil)
        let groups = board.cards(now: now)[0].groups
        try expectEqual(groups[0].buckets.map(\.extraLabel), [nil, nil, "Argon Weekly Limit", "carbon-weekly", nil])
        try expectEqual(groups[1].buckets.map(\.extraLabel), [nil])
    }

    static func windowOrder() throws {
        // 周窗口与 5 小时窗口交错：5 小时窗口按接口顺序排到前面，周窗口按接口顺序跟在后面
        let quota = AntigravityAccountQuota(
            email: pro, tierName: nil, tierId: nil,
            groups: [
                AntigravityQuotaGroup(kind: .gemini, displayName: "Gemini Models", models: [],
                                      buckets: [bucket("w1", .weekly, remaining: 10, name: "Weekly A"),
                                                bucket("h1", .fiveHour, remaining: 20, name: "5h X"),
                                                bucket("w2", .weekly, remaining: 30, name: "Weekly B"),
                                                bucket("h2", .fiveHour, remaining: 40, name: "5h Y")]),
                AntigravityQuotaGroup(kind: .other, displayName: "Only weekly", models: [],
                                      buckets: [bucket("w3", .weekly, remaining: 50)]),
            ],
            fetchedAt: now)
        var board = added(pro)
        board.record(.success(quota), clicked: nil)
        let groups = board.cards(now: now)[0].groups
        try expectEqual(groups.map(\.displayName), ["Gemini Models", "Only weekly"])
        try expectEqual(groups[0].buckets.map(\.bucketId), ["h1", "h2", "w1", "w2"])
        try expectEqual(groups[0].buckets.map(\.extraLabel), [nil, "5h Y", nil, "Weekly B"])
        try expectEqual(groups[0].buckets.map(\.reading), [.remaining(20, tint: .red), .remaining(40, tint: .yellow),
                                                            .remaining(10, tint: .red), .remaining(30, tint: .yellow)])
        try expectEqual(groups[1].buckets.map(\.bucketId), ["w3"])
        // 统计面板的圆环同一顺序
        try expectEqual(try unwrap(board.flyout(for: pro, now: now)).groups[0].rings.map(\.bucket.bucketId),
                        ["h1", "h2", "w1", "w2"])
    }

    static func unaddedEmailRead() throws {
        var board = added(ultra, pro)
        board.record(.success(ultraQuota()), clicked: nil)
        board.record(.notSignedIn, clicked: pro)
        board.record(.failed(email: ultra, reason: .networkFailure), clicked: ultra)
        try expectEqual(problems(board), [.failed(.networkFailure), .notSignedIn])
        let saved = board.saved

        // 刷新全部读到没添加的邮箱：不建卡片、不存数据，但记为最后读到，需要写回
        let other = "other@example.com"
        let effect = board.record(.success(ultraQuota(email: other)), clicked: nil)
        try expectEqual(effect, AntigravityRecordEffect(notices: [], needsSave: true))
        try expectEqual(board.emails, [ultra, pro])
        try expectEqual(board.saved, saved, "没有存它的数据")
        try expectEqual(board.lastReadEmail, other)
        // 已添加的卡片全部变灰、没有"当前"
        let cards = board.cards(now: at(minutes: 1))
        try expectEqual(cards.map(\.isOldSnapshot), [true, true])
        try expectEqual(readings(cards[0])[0]["gemini-5h"], .remaining(71, tint: .stale))
        // 不知道账号时落下的原因清掉；ultra 自己的原因留着
        try expectEqual(problems(board), [.failed(.networkFailure), nil])

        // 没有邮箱、刷新全部：最后读到的没有卡片，原因不落在任何卡片
        board.record(.failed(email: nil, reason: .noReachablePort), clicked: nil)
        try expectEqual(problems(board), [.failed(.networkFailure), nil])

        // 存下、读回：最后读到的是没添加的邮箱，卡片仍都是旧快照
        let home = try TempHome()
        defer { home.remove() }
        let store = AntigravityBoardStore(environment: home.environment)
        try store.save(board)
        try expectEqual(store.load().cards(now: at(minutes: 1)).map(\.isOldSnapshot), [true, true])
        try expectEqual(store.load().lastReadEmail, other)

        // 之后添加这个邮箱：没有数据（还没读到过），最后读到的就是它，标为当前
        board.add(other)
        let card = board.cards(now: at(minutes: 1))[2]
        try expectEqual(card.isNotReadYet, true)
        try expectEqual(card.isOldSnapshot, false)
        try expectEqual(card.groups, [])
    }

    static func caseInsensitive() throws {
        let typed = "Ultra@Example.com"
        var board = added(typed, pro)

        // 读到的写法不同：落到这张卡片，卡片和快照保持添加时的写法
        var effect = board.record(.success(ultraQuota()), clicked: typed)
        try expectEqual(effect, AntigravityRecordEffect(notices: [], needsSave: true), "被点的卡片就是读到的，没有提示")
        try expectEqual(board.emails, [typed, pro])
        var cards = board.cards(now: at(minutes: 1))
        try expectEqual(cards[0].isOldSnapshot, false)
        try expectEqual(cards[0].groups.count, 2)
        try expectEqual(board.lastReadEmail, typed)

        // 失败、格式无法识别带邮箱：同样落到这张卡片
        effect = board.record(.failed(email: "ULTRA@example.com", reason: .httpStatus(500)), clicked: "ultra@EXAMPLE.com")
        try expectEqual(effect.notices, [])
        try expectEqual(problems(board), [.failed(.httpStatus(500)), nil])
        board.record(.unrecognizedFormat(email: ultra), clicked: pro)
        cards = board.cards(now: at(minutes: 1))
        try expectEqual(cards[0].groups, [])
        try expectEqual(cards[0].problem, .unrecognizedFormat)

        // 存下读回不变（快照里的邮箱也是卡片的写法）
        board.record(.success(ultraQuota()), clicked: nil)
        let home = try TempHome()
        defer { home.remove() }
        let store = AntigravityBoardStore(environment: home.environment)
        try store.save(board)
        try expectEqual(store.load(), board)

        // 删除不分大小写；删的是最后读到的
        board.remove("ultra@example.COM")
        try expectEqual(board.emails, [pro])
        try expectEqual(board.lastReadEmail, nil)
    }

    // MARK: - 失败、提示

    static func problems(_ board: AntigravityBoard) -> [AntigravityProblem?] {
        board.cards(now: at(minutes: 1)).map(\.problem)
    }

    static func unrecognizedWithEmail() throws {
        var board = added(ultra, pro)
        board.record(.success(ultraQuota()), clicked: nil)
        board.record(.success(proQuota()), clicked: nil)

        let effect = board.record(.unrecognizedFormat(email: ultra), clicked: ultra)
        try expectEqual(effect, AntigravityRecordEffect(notices: [], needsSave: true))
        let card = board.cards(now: at(minutes: 1))[0]
        try expectEqual(card.email, ultra)
        try expectEqual(card.problem, .unrecognizedFormat)
        try expectEqual(card.groups, [])
        try expectEqual(card.fetchedAt, nil)
        try expectEqual(card.tierName, nil)
        // 别的邮箱不受影响；"最后读到"不变（格式无法识别不算成功读到）
        try expectEqual(board.cards(now: at(minutes: 1))[1].groups.count, 1)
        try expectEqual(board.lastReadEmail, pro)

        // 再来一次：没有数据可丢了，不用写回
        try expectEqual(board.record(.unrecognizedFormat(email: ultra), clicked: ultra).needsSave, false)
    }

    static func unrecognizedWithoutEmail() throws {
        var board = added(ultra, pro)
        board.record(.success(ultraQuota()), clicked: nil)
        board.record(.success(proQuota()), clicked: nil)

        let effect = board.record(.unrecognizedFormat(email: nil), clicked: ultra)
        try expectEqual(effect, AntigravityRecordEffect(notices: [], needsSave: false))
        try expectEqual(problems(board), [.unrecognizedFormat, nil])
        try expectEqual(board.cards(now: at(minutes: 1)).map(\.groups.count), [2, 1])

        var all = added(ultra, pro)
        all.record(.success(ultraQuota()), clicked: nil)
        all.record(.success(proQuota()), clicked: nil)
        all.record(.unrecognizedFormat(email: nil), clicked: nil)
        try expectEqual(problems(all), [nil, .unrecognizedFormat])
        try expectEqual(all.cards(now: at(minutes: 1)).map(\.groups.count), [2, 1])
    }

    static func failures() throws {
        var board = added(ultra, pro)
        board.record(.success(ultraQuota()), clicked: nil)
        board.record(.success(proQuota()), clicked: nil)

        // 带邮箱：落在读到的邮箱（点的就是它）
        var effect = board.record(.failed(email: pro, reason: .httpStatus(500)), clicked: pro)
        try expectEqual(effect, AntigravityRecordEffect(notices: [], needsSave: false))
        try expectEqual(problems(board), [nil, .failed(.httpStatus(500))])
        // 快照保留，仍是最后读到的
        let card = board.cards(now: at(minutes: 1))[1]
        try expectEqual(card.isOldSnapshot, false)
        try expectEqual(readings(card), [["argon-weekly": .remaining(64, tint: .green)]])

        // 没有邮箱：落在被点的卡片
        effect = board.record(.failed(email: nil, reason: .noReachablePort), clicked: ultra)
        try expectEqual(effect, AntigravityRecordEffect(notices: [], needsSave: false))
        try expectEqual(problems(board), [.failed(.noReachablePort), .failed(.httpStatus(500))])

        // 没有邮箱、刷新全部：落在最后读到的
        board.record(.failed(email: nil, reason: .processUnreadable), clicked: nil)
        try expectEqual(problems(board), [.failed(.noReachablePort), .failed(.processUnreadable)])

        // 成功：清掉这个邮箱的原因
        board.record(.success(proQuota()), clicked: pro)
        try expectEqual(problems(board)[1], nil)
    }

    static func notSignedIn() throws {
        var empty = AntigravityBoard()
        try expectEqual(empty.record(.notSignedIn, clicked: nil), AntigravityRecordEffect(notices: [], needsSave: false))
        try expectEqual(empty.cards(now: now), [])

        var board = added(ultra, pro)
        board.record(.success(ultraQuota()), clicked: nil)
        board.record(.success(proQuota()), clicked: nil)
        board.record(.notSignedIn, clicked: ultra)
        try expectEqual(problems(board), [.notSignedIn, nil])
        try expectEqual(board.cards(now: at(minutes: 1)).map(\.groups.count), [2, 1])

        var all = added(ultra, pro)
        all.record(.success(ultraQuota()), clicked: nil)
        all.record(.success(proQuota()), clicked: nil)
        all.record(.notSignedIn, clicked: nil)
        try expectEqual(problems(all), [nil, .notSignedIn])
    }

    static func appNotRunning() throws {
        var board = added(ultra)
        board.record(.success(ultraQuota()), clicked: nil)
        board.record(.failed(email: ultra, reason: .networkFailure), clicked: ultra)
        let before = board

        let effect = board.record(.appNotRunning, clicked: ultra)
        try expectEqual(effect, AntigravityRecordEffect(
            notices: [AntigravityNotice(card: ultra, kind: .openAppToRefresh)], needsSave: false))
        try expectEqual(board, before)

        try expectEqual(board.record(.appNotRunning, clicked: nil), AntigravityRecordEffect(notices: [], needsSave: false))
        try expectEqual(board, before)

        var empty = AntigravityBoard()
        try expectEqual(empty.record(.appNotRunning, clicked: nil), AntigravityRecordEffect(notices: [], needsSave: false))
        try expectEqual(empty.cards(now: now), [])
    }

    static func signedInAsNotice() throws {
        var board = added(ultra)
        board.record(.success(ultraQuota()), clicked: nil)

        // 点 ultra，读到没添加的 pro：不建卡片，ultra 得到提示
        var effect = board.record(.success(proQuota()), clicked: ultra)
        try expectEqual(effect, AntigravityRecordEffect(
            notices: [AntigravityNotice(card: ultra, kind: .signedInAs(pro))], needsSave: true))
        try expectEqual(board.cards(now: at(minutes: 1)).map(\.email), [ultra])

        // 读到已添加的 pro 同样给
        board.add(pro)
        effect = board.record(.success(proQuota()), clicked: ultra)
        try expectEqual(effect.notices, [AntigravityNotice(card: ultra, kind: .signedInAs(pro))])
        try expectEqual(board.cards(now: at(minutes: 1)).map(\.email), [ultra, pro])

        // 失败、格式无法识别带邮箱时也给
        effect = board.record(.failed(email: pro, reason: .networkFailure), clicked: ultra)
        try expectEqual(effect.notices, [AntigravityNotice(card: ultra, kind: .signedInAs(pro))])
        try expectEqual(problems(board), [nil, .failed(.networkFailure)])
        effect = board.record(.unrecognizedFormat(email: pro), clicked: ultra)
        try expectEqual(effect.notices, [AntigravityNotice(card: ultra, kind: .signedInAs(pro))])

        // 点的就是读到的、刷新全部：没有提示
        try expectEqual(board.record(.success(proQuota()), clicked: pro).notices, [])
        try expectEqual(board.record(.success(ultraQuota()), clicked: nil).notices, [])
    }

    static func joinedClicks() throws {
        // 点 ultra 发起读取；读取进行中点 pro、再点 ultra、点刷新全部：都不发起新的读取
        var refreshing = AntigravityRefreshing()
        try expectEqual(refreshing.isRunning, false)
        try expectEqual(refreshing.isSpinning(ultra), false)
        try expectEqual(refreshing.click(ultra), true)
        try expectEqual(refreshing.click(pro), false)
        try expectEqual(refreshing.click(ultra), false)
        try expectEqual(refreshing.clickRefreshAll(), false)
        try expectEqual(refreshing.isRunning, true)
        try expectEqual([ultra, pro, "other@example.com"].map(refreshing.isSpinning), [true, true, false])
        try expectEqual(refreshing.finish(), [ultra, pro])
        try expectEqual(refreshing.isRunning, false)
        try expectEqual([ultra, pro].map(refreshing.isSpinning), [false, false])

        // 刷新全部发起：所有卡片转圈；进行中点 ultra 也算被点的卡片
        try expectEqual(refreshing.clickRefreshAll(), true)
        try expectEqual([ultra, pro].map(refreshing.isSpinning), [true, true])
        try expectEqual(refreshing.click(ultra), false)
        try expectEqual(refreshing.finish(), [ultra])
        try expectEqual(refreshing.finish(), [], "结束后没有被点的卡片")

        // 两张卡片都被点：读到 pro 时只有 ultra 得到"登录的是 pro"；App 没开时两张都得到提示
        var board = added(ultra, pro)
        board.record(.success(ultraQuota()), clicked: nil)
        board.record(.success(proQuota()), clicked: nil)
        try expectEqual(board.record(.success(proQuota()), clicked: [ultra, pro]).notices,
                        [AntigravityNotice(card: ultra, kind: .signedInAs(pro))])
        try expectEqual(board.record(.appNotRunning, clicked: [pro, ultra]).notices,
                        [AntigravityNotice(card: pro, kind: .openAppToRefresh),
                         AntigravityNotice(card: ultra, kind: .openAppToRefresh)])
        // 读到没添加的第三个邮箱：两张都得到提示，不建卡片
        let third = ultraQuota(email: "third@example.com")
        try expectEqual(board.record(.success(third), clicked: [ultra, pro]).notices,
                        [AntigravityNotice(card: ultra, kind: .signedInAs(third.email)),
                         AntigravityNotice(card: pro, kind: .signedInAs(third.email))])
        try expectEqual(board.emails, [ultra, pro])
        // 不知道是哪个账号的原因只落在发起读取的那张
        board.record(.notSignedIn, clicked: [pro, ultra])
        try expectEqual(problems(board), [nil, .notSignedIn])
        // 读取期间被删掉的卡片没有提示
        board.remove(pro)
        try expectEqual(board.record(.appNotRunning, clicked: [pro, ultra]).notices,
                        [AntigravityNotice(card: ultra, kind: .openAppToRefresh)])
    }

    static func failureForUnknownEmail() throws {
        var board = added(ultra)
        board.record(.success(ultraQuota()), clicked: nil)

        var effect = board.record(.failed(email: pro, reason: .httpStatus(503)), clicked: ultra)
        try expectEqual(effect, AntigravityRecordEffect(
            notices: [AntigravityNotice(card: ultra, kind: .signedInAs(pro))], needsSave: false))
        try expectEqual(board.cards(now: at(minutes: 1)).map(\.email), [ultra])
        try expectEqual(problems(board), [.failed(.httpStatus(503))])

        effect = board.record(.unrecognizedFormat(email: pro), clicked: ultra)
        try expectEqual(effect.needsSave, false)
        try expectEqual(board.cards(now: at(minutes: 1)).map(\.email), [ultra])
        try expectEqual(problems(board), [.unrecognizedFormat])
        try expectEqual(board.cards(now: at(minutes: 1))[0].groups.count, 2)

        // 刷新全部、看板是空的：没有卡片可落，什么都不显示
        var empty = AntigravityBoard()
        empty.record(.failed(email: pro, reason: .httpStatus(503)), clicked: nil)
        try expectEqual(empty.cards(now: now), [])
    }

    static func accountlessProblemsClear() throws {
        var board = added(ultra, pro)
        board.record(.success(ultraQuota()), clicked: nil)
        board.record(.success(proQuota()), clicked: nil)
        board.record(.notSignedIn, clicked: ultra)
        board.record(.failed(email: pro, reason: .networkFailure), clicked: pro)
        try expectEqual(problems(board), [.notSignedIn, .failed(.networkFailure)])

        // 读到另一个账号（点的是 pro、读到的就是 pro）：ultra 的"未登录"不再成立；pro 自己的原因被成功清掉
        board.record(.success(proQuota()), clicked: pro)
        try expectEqual(problems(board), [nil, nil])

        // 有账号的原因只由这个邮箱自己的成功清掉
        board.record(.failed(email: ultra, reason: .httpStatus(500)), clicked: ultra)
        board.record(.success(proQuota()), clicked: pro)
        try expectEqual(problems(board), [.failed(.httpStatus(500)), nil])
        board.record(.unrecognizedFormat(email: nil), clicked: ultra)
        board.record(.success(proQuota()), clicked: pro)
        try expectEqual(problems(board), [nil, nil])
    }

    // MARK: - 删除

    static func remove() throws {
        var board = added(ultra, pro)
        board.record(.success(ultraQuota()), clicked: nil)
        board.record(.success(proQuota()), clicked: nil)
        board.record(.failed(email: pro, reason: .networkFailure), clicked: pro)

        board.remove(pro)
        try expectEqual(board.cards(now: at(minutes: 1)).map(\.email), [ultra])
        // 最后读到的被删了：剩下的都是旧快照
        try expectEqual(board.lastReadEmail, nil)
        try expectEqual(board.cards(now: at(minutes: 1)).map(\.isOldSnapshot), [true])

        // 再读到同一邮箱：不重新出现，不存它的数据
        let effect = board.record(.success(proQuota(fetchedAt: at(minutes: 2))), clicked: ultra)
        try expectEqual(effect.notices, [AntigravityNotice(card: ultra, kind: .signedInAs(pro))])
        try expectEqual(board.emails, [ultra])
        try expectEqual(board.saved.map(\.email), [ultra])

        // 要再手动添加：排在后面，还没读到过，原来的失败原因、快照都不留下
        try expectEqual(board.add(pro), true)
        var cards = board.cards(now: at(minutes: 3))
        try expectEqual(cards.map(\.email), [ultra, pro])
        try expectEqual(cards[1].isNotReadYet, true)
        try expectEqual(cards[1].problem, nil)
        try expectEqual(cards[1].groups, [])
        board.record(.success(proQuota(fetchedAt: at(minutes: 4))), clicked: pro)
        cards = board.cards(now: at(minutes: 5))
        try expectEqual(cards.map(\.isOldSnapshot), [true, false])
        try expectEqual(cards[1].fetchedAt, at(minutes: 4))

        // 删不存在的邮箱：什么都不变
        let before = board
        board.remove("nobody@example.com")
        try expectEqual(board, before)
    }

    // MARK: - 持久化

    static func persistRoundTrip() throws {
        let home = try TempHome()
        defer { home.remove() }
        let store = AntigravityBoardStore(environment: home.environment)
        try expectEqual(store.fileURL.path,
                        home.url.path + "/Library/Application Support/cc-pilot/antigravity-snapshots.json")
        try expectEqual(store.fileURL.deletingLastPathComponent(),
                        TokenLedger.defaultURL(environment: home.environment).deletingLastPathComponent())

        // 读取时间带小数秒：存取不能丢精度
        let fetched = now.addingTimeInterval(0.123456)
        var board = added(ultra, pro)
        board.record(.success(ultraQuota(fetchedAt: fetched)), clicked: nil)
        let proFull = AntigravityAccountQuota(
            email: pro, tierName: "Google AI Pro", tierId: "g1-pro-tier",
            groups: [
                AntigravityQuotaGroup(kind: .gemini, displayName: "Gemini Models", models: [],
                                      buckets: [bucket("gemini-5h", .fiveHour, remaining: 50, name: "5h Limit"),
                                                bucket("gemini-weekly", .weekly, remaining: 33.3),
                                                bucket("argon-weekly", .weekly, remaining: 0, resetIn: nil)]),
                AntigravityQuotaGroup(kind: .other, displayName: "Gemini 4 Argon",
                                      models: ["For paid Pro plans, Argon quota is separate."],
                                      buckets: [AntigravityQuotaBucket(bucketId: nil, displayName: nil, window: .weekly,
                                                                       usage: nil)]),
            ],
            fetchedAt: at(minutes: 1))
        board.record(.success(proQuota()), clicked: nil)  // 先有一个旧的，再换成上面的
        board.record(.success(proFull), clicked: nil)
        try store.save(board)

        let loaded = store.load()
        try expectEqual(loaded, board)
        try expectEqual(loaded.lastReadEmail, pro)
        try expectEqual(loaded.cards(now: at(minutes: 2)), board.cards(now: at(minutes: 2)))
        try expectEqual(loaded.cards(now: at(minutes: 2))[0].fetchedAt, fetched)
    }

    static func persistRemoval() throws {
        let home = try TempHome()
        defer { home.remove() }
        let store = AntigravityBoardStore(environment: home.environment)
        try expectEqual(store.load(), AntigravityBoard())

        var board = added(ultra, pro)
        board.record(.success(ultraQuota()), clicked: nil)
        board.record(.success(proQuota()), clicked: nil)
        try store.save(board)

        board.remove(ultra)
        try store.save(board)
        try expectEqual(store.load().cards(now: now).map { $0.email }, [pro])

        // 失败原因不存：读回的卡片没有原因
        board.record(.failed(email: pro, reason: .networkFailure), clicked: nil)
        try store.save(board)
        try expectEqual(store.load().cards(now: now).map { $0.problem }, [nil])
    }

    static func persistDataless() throws {
        let home = try TempHome()
        defer { home.remove() }
        let store = AntigravityBoardStore(environment: home.environment)
        var board = added(ultra, pro)
        board.record(.success(ultraQuota()), clicked: nil)
        board.record(.success(proQuota()), clicked: nil)
        let effect = board.record(.unrecognizedFormat(email: ultra), clicked: ultra)
        try expectEqual(effect.needsSave, true)
        try store.save(board)

        // 重启：卡片还在、位置不变，没有数据，显示接口可能已变化；"最后读到"不变
        var loaded = store.load()
        try expectEqual(loaded.cards(now: at(minutes: 1)), board.cards(now: at(minutes: 1)))
        let cards = loaded.cards(now: at(minutes: 1))
        try expectEqual(cards.map(\.email), [ultra, pro])
        try expectEqual(cards[0].problem, .unrecognizedFormat)
        try expectEqual(cards[0].groups, [])
        try expectEqual(cards[0].fetchedAt, nil)
        try expectEqual(cards[0].tierName, nil)
        try expectEqual(cards[1].groups.count, 1)
        try expectEqual(loaded.lastReadEmail, pro)

        // 点它刷新、App 里没登录，再读到别的账号：未登录的原因清掉后，回到接口可能已变化（与重启后一致）
        loaded.record(.notSignedIn, clicked: ultra)
        try expectEqual(problems(loaded), [.notSignedIn, nil])
        loaded.record(.success(proQuota()), clicked: pro)
        try expectEqual(problems(loaded), [.unrecognizedFormat, nil])
        // 别的邮箱失败、刷新全部不影响它
        loaded.record(.failed(email: nil, reason: .noReachablePort), clicked: nil)
        try expectEqual(problems(loaded)[0], .unrecognizedFormat)

        // 这个邮箱下次成功：数据回来，原因清掉，存下后读回也是
        loaded.record(.success(ultraQuota(fetchedAt: at(minutes: 2))), clicked: ultra)
        try expectEqual(problems(loaded), [nil, nil])
        try store.save(loaded)
        let again = store.load().cards(now: at(minutes: 3))
        try expectEqual(again.map(\.problem), [nil, nil])
        try expectEqual(again[0].groups.count, 2)

        // 删掉没有数据的卡片：读回时没有了
        loaded.record(.unrecognizedFormat(email: ultra), clicked: ultra)
        loaded.remove(ultra)
        try store.save(loaded)
        try expectEqual(store.load().emails, [pro])
    }

    static func persistReadsVersion1() throws {
        let home = try TempHome()
        defer { home.remove() }
        let store = AntigravityBoardStore(environment: home.environment)
        // 版本 1 的文件（ticket 02 起写的格式）：每个账号都有数据
        let fetched = now.timeIntervalSinceReferenceDate
        try home.write("Library/Application Support/cc-pilot/antigravity-snapshots.json", """
            {"version": 1, "lastReadEmail": "\(pro)",
             "accounts": [
              {"email": "\(ultra)", "tierName": "Google AI Ultra", "tierId": "g1-ultra-lite-tier", "fetchedAt": \(fetched),
               "groups": [{"kind": "gemini", "displayName": "Gemini Models", "models": ["Gemini 3 Pro"],
                           "buckets": [{"bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining",
                                        "window": "weekly", "usage": {"utilization": 7.5, "resetsAt": \(fetched + 3600)}},
                                       {"bucketId": "gemini-5h", "window": "5h", "usage": {"utilization": 29}}]},
                          {"kind": "thirdParty", "displayName": "Claude and GPT models", "models": [], "buckets": []},
                          {"kind": "other", "displayName": "Gemini 4 Argon", "models": [], "buckets": []}]},
              {"email": "\(pro)", "fetchedAt": \(fetched), "groups": []}]}
            """)
        let board = store.load()
        try expectEqual(board.emails, [ultra, pro])
        try expectEqual(board.lastReadEmail, pro)
        let card = board.cards(now: at(minutes: 1))[0]
        try expectEqual(card.tierName, "Google AI Ultra")
        try expectEqual(card.fetchedAt, now)
        try expectEqual(card.problem, nil)
        try expectEqual(card.groups.map(\.kind), [.gemini, .thirdParty, .other])
        try expectEqual(card.groups.map(\.displayName), ["Gemini Models", "Claude and GPT models", "Gemini 4 Argon"])
        try expectEqual(card.groups[0].models, ["Gemini 3 Pro"])
        try expectEqual(card.groups[0].buckets.map(\.bucketId), ["gemini-5h", "gemini-weekly"])
        try expectEqual(card.groups[0].buckets.map(\.reading), [.remaining(71, tint: .stale), .remaining(92, tint: .stale)])
        try expectEqual(card.groups[0].buckets[1].resetsAt, at(minutes: 60))
        try expectEqual(board.cards(now: at(minutes: 1))[1].problem, nil)

        try store.save(board)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        try expectEqual(saved?["version"] as? Int, 3)
        try expectEqual(store.load(), board)
    }

    static func persistReadsVersion2() throws {
        let home = try TempHome()
        defer { home.remove() }
        let store = AntigravityBoardStore(environment: home.environment)
        let fetched = now.timeIntervalSinceReferenceDate
        try home.write("Library/Application Support/cc-pilot/antigravity-snapshots.json", """
            {"version": 2, "lastReadEmail": "\(pro)",
             "accounts": [
              {"email": "\(ultra)"},
              {"email": "\(pro)", "tierName": "Google AI Pro", "fetchedAt": \(fetched),
               "groups": [{"kind": "other", "displayName": "Gemini 4 Argon", "models": [],
                           "buckets": [{"bucketId": "argon-weekly", "window": "weekly", "usage": {"utilization": 36}}]}]}]}
            """)
        var board = store.load()
        try expectEqual(board.emails, [ultra, pro])
        try expectEqual(board.lastReadEmail, pro)
        let cards = board.cards(now: at(minutes: 1))
        try expectEqual(cards.map(\.problem), [.unrecognizedFormat, nil])
        try expectEqual(cards.map(\.isNotReadYet), [false, false])
        try expectEqual(readings(cards[1]), [["argon-weekly": .remaining(64, tint: .green)]])

        // 都当作已添加：再读到它们照常落到卡片上，不能重复添加
        try expectEqual(board.problem(forNewEmail: ultra), .exists)
        board.record(.success(ultraQuota()), clicked: nil)
        try expectEqual(board.cards(now: at(minutes: 1))[0].groups.count, 2)

        try store.save(board)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        try expectEqual(saved?["version"] as? Int, 3)
        try expectEqual(store.load(), board)
    }

    static func persistNotReadYet() throws {
        let home = try TempHome()
        defer { home.remove() }
        let store = AntigravityBoardStore(environment: home.environment)
        let third = "third@example.com"
        let board = {
            var board = added(ultra, pro, third)
            board.record(.success(ultraQuota()), clicked: nil)
            board.record(.unrecognizedFormat(email: ultra), clicked: nil)
            board.record(.success(proQuota()), clicked: nil)
            return board
        }()
        try store.save(board)

        var loaded = store.load()
        try expectEqual(loaded.cards(now: at(minutes: 1)), board.cards(now: at(minutes: 1)))
        let cards = loaded.cards(now: at(minutes: 1))
        try expectEqual(cards.map(\.email), [ultra, pro, third])
        try expectEqual(cards.map(\.isNotReadYet), [false, false, true])
        try expectEqual(cards.map(\.problem), [.unrecognizedFormat, nil, nil])
        try expectEqual(cards[2].fetchedAt, nil)

        // 文件里的写法
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        let accounts = json?["accounts"] as? [[String: Any]] ?? []
        try expectEqual(accounts.map { $0["noData"] as? String }, ["unrecognizedFormat", nil, "notReadYet"])
        try expectEqual(accounts.map { $0.keys.sorted() }, [["email", "noData"],
                                                            ["email", "fetchedAt", "groups", "tierId", "tierName"],
                                                            ["email", "noData"]])

        // 还没读到过的卡片：格式无法识别带它的邮箱时变成"接口可能已变化"，需要写回，重启后照样
        try expectEqual(loaded.record(.unrecognizedFormat(email: third), clicked: third).needsSave, true)
        try store.save(loaded)
        let after = store.load().cards(now: at(minutes: 1))[2]
        try expectEqual(after.isNotReadYet, false)
        try expectEqual(after.problem, .unrecognizedFormat)
    }

    static func persistCorrupt() throws {
        let home = try TempHome()
        defer { home.remove() }
        let store = AntigravityBoardStore(environment: home.environment)
        let relative = "Library/Application Support/cc-pilot/antigravity-snapshots.json"

        for text in ["", "not json", "[]", #"{"version": 1}"#, #"{"version": 99, "accounts": []}"#,
                     #"{"version": 1, "accounts": [{"email": "a@example.com"}]}"#,
                     // 版本 2 里没有数据的账号两项都不写；只写一项的不对
                     #"{"version": 2, "accounts": [{"email": "a@example.com", "fetchedAt": 1800000000}]}"#,
                     #"{"version": 2, "accounts": [{"email": "a@example.com", "groups": []}]}"#,
                     // 版本 3 里没有数据的账号要有 noData；有数据的不能有；noData 只认两种；版本 2 没有 noData
                     #"{"version": 3, "accounts": [{"email": "a@example.com"}]}"#,
                     #"{"version": 3, "accounts": [{"email": "a@example.com", "noData": "gone"}]}"#,
                     #"{"version": 3, "accounts": [{"email": "a@example.com", "fetchedAt": 1800000000, "groups": [], "noData": "notReadYet"}]}"#,
                     #"{"version": 3, "accounts": [{"email": "a@example.com", "fetchedAt": 1800000000, "noData": "notReadYet"}]}"#,
                     #"{"version": 2, "accounts": [{"email": "a@example.com", "noData": "notReadYet"}]}"#,
                     #"{"version": 1, "accounts": [{"email": "a@example.com", "fetchedAt": 1800000000, "groups": [{"kind": "gemini", "displayName": "G", "models": [], "buckets": [{"window": "daily"}]}]}]}"#] {
            try home.write(relative, text)
            try expectEqual(store.load(), AntigravityBoard(), "文件内容：\(text)")
        }

        // 是目录：读不出
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        try expectEqual(store.load(), AntigravityBoard())
        try FileManager.default.removeItem(at: store.fileURL)

        // 存的内容只有快照：没有 csrf token（AntigravityRefreshChecks.token）、没有失败原因
        var board = added(ultra)
        board.record(.success(ultraQuota()), clicked: nil)
        board.record(.failed(email: ultra, reason: .httpStatus(500)), clicked: nil)
        try store.save(board)
        let saved = try String(contentsOf: store.fileURL, encoding: .utf8)
        try expect(!saved.contains(AntigravityRefreshChecks.token), "存下了 csrf token")
        try expect(!saved.lowercased().contains("csrf"), "存下了 csrf 字段")
        try expect(!saved.contains("httpStatus") && !saved.contains("problem"), "存下了失败原因")
        try expect(saved.contains(ultra), "没有存邮箱")
    }
}
