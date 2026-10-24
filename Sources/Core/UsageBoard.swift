// 已获取的额度，按账号保存（只在内存里，只用于显示；不含凭据）。
//
// 界面持有一个 UsageBoard：刷新得到的 UsageRefreshOutcome 交给 record(_:)，
// 档案行按档案查 usage(for:)，菜单栏用 menuBarSummary(currentProfile:profiles:now:)。
// 点刷新时先用 accountsAllowedToRefresh(_:now:) 去掉还在频率限制等待期内的账号。
// 查询不读文件、不读钥匙串、不联网，所以打开面板、启动 App、切换档案、重载档案列表都不会触发请求。
//
// 失败时怎么办（ticket 12）：
//   网络失败、其他状态码、401、频率限制 → 保留上一次成功获取的数据（带着它自己的获取时间），记下原因
//   频率限制                            → 另记下下一次允许请求的时间
//   格式无法识别                        → 丢掉旧的刷新数据，两个窗口都显示"—"（接口可能已变化）；
//                                         来自实时额度的窗口另有来源，照常显示
//   成功                                → 替换数据，清除原因和等待时间
//                                         （两个主窗口按下面的合并规则并入，不一定替换）
//
// 实时额度（token-usage ticket 05）：recordLive(_:profiles:) 按档案找到账号，把状态栏转发来的 5 小时窗口和
// "全部模型"周窗口并入；按模型细分的周窗口、超额付费只来自刷新。实时额度不发请求，也不碰失败原因和频率限制。
// 两个主窗口的合并规则见 ObservedWindow.merging(_:)。
// 实时额度文件里没有账号，只有档案名：档案换登录后，换之前写的那份文件属于旧账号，不能并入新账号
// （否则旧账号的数字会因 resets_at 更晚压过新账号的刷新结果）。所以记住每个档案上次并入时的账号，
// 发现换了账号时记下这个时刻，之后只并入在这之后写的文件（received_at 更晚）。第一次见到档案时不设限
// （App 没运行时换的登录无从得知，按档案当前的账号算）。

import Foundation

/// 最近一次刷新失败的原因（界面据此提示用户）
enum UsageProblem: Equatable {
    /// 没有发请求（登录状态不是"可以请求额度"），或收到 401
    case login(LoginStatus)
    /// 429 / 403：频率限制，等待时间见 AccountUsage.retryAt
    case rateLimited
    /// 其他状态码
    case httpStatus(Int)
    /// 网络失败或超时
    case networkFailure
    /// 响应格式无法识别：接口可能已变化，请更新 cc-pilot
    case unrecognizedFormat
}

/// 按模型细分的一个周窗口此刻怎么显示（展开账号后的详情）
struct ModelWeeklyReading: Equatable {
    /// 模型名；nil 时界面用通用标题
    let model: String?
    let reading: UsageReading
    let resetsAt: Date?
}

/// 合并后的一个主窗口（5 小时、"全部模型"周窗口）：显示的数值，以及判断变灰用的时间
struct ObservedWindow: Equatable {
    enum Source: Equatable {
        /// 刷新（用户点刷新、请求额度接口）
        case refresh
        /// 实时额度（状态栏转发）
        case live
    }

    let window: UsageWindow
    /// 这个数值最后一次被观察到的时间：它成为合并结果的那次数据的时间（刷新的获取时间，或实时额度文件的
    /// received_at），之后被刷新确认时更新为那次刷新的获取时间。变灰按它算。
    let observedAt: Date
    /// 数值来自哪里（格式无法识别时只丢掉来自刷新的数值）
    let source: Source

    /// 两份 resets_at 相差不超过这么多算同一个窗口：刷新给的 ISO 时间去掉了小数秒，状态栏给的是整数秒，
    /// 两者对同一个窗口可能差一点。窗口之间至少相隔 5 小时，这个容差不会把两个窗口混为一谈。
    static let sameWindowTolerance: TimeInterval = 5 * 60

    /// 并入另一份数据（刷新结果或实时额度），返回合并后的窗口。规则（spec 决定 9，ticket 04 实测修订）：
    ///   - resets_at 更晚的优先：那是更新的窗口，旧窗口的数据不再有意义。
    ///   - resets_at 相同（容差内）：取已用百分比最高的那份。同一窗口内用量只增不减，较低的那份必然是旧数据。
    ///     不能按时间取较新：实时额度文件的 received_at 是写文件时间，不是数据时间——状态栏重绘会带着旧的
    ///     rate_limits 重写文件，同一档案的两个会话也会互相覆盖。
    ///   - 任一方没有 resets_at：无法判断是不是同一个窗口，取观察时间较新的（与接入实时额度前的刷新行为一致）。
    /// 变灰用的时间（observedAt）：
    ///   - 换成另一份数值时，取那份数据的时间。
    ///   - 数值相同（显示的剩余百分比相同）时，刷新算确认，observedAt 更新为刷新的获取时间；实时额度不算确认，
    ///     因为它的 received_at 可能只是重绘时间——否则一个空闲却不断重绘的会话会让旧数字永远不变灰。
    func merging(_ candidate: ObservedWindow) -> ObservedWindow {
        guard let mine = window.resetsAt, let theirs = candidate.window.resetsAt else {
            return candidate.observedAt >= observedAt ? candidate : self
        }
        if theirs.timeIntervalSince(mine) > Self.sameWindowTolerance { return candidate }
        if mine.timeIntervalSince(theirs) > Self.sameWindowTolerance { return self }
        if candidate.window.utilization > window.utilization { return candidate }
        if candidate.source == .refresh, candidate.window.remainingPercent == window.remainingPercent,
           candidate.observedAt > observedAt {
            return ObservedWindow(window: window, observedAt: candidate.observedAt, source: source)
        }
        return self
    }
}

extension Optional where Wrapped == ObservedWindow {
    /// 并入一份数据；还没有数据时直接采用它
    func merging(_ candidate: ObservedWindow) -> ObservedWindow {
        self?.merging(candidate) ?? candidate
    }
}

/// 一个账号的额度状态
struct AccountUsage: Equatable {
    /// 最近一次成功获取的数据（含获取时间）；从没成功过、或之后格式无法识别时为 nil。
    /// 两个主窗口不要从这里读（那只是刷新的一半），用 fiveHourWindow / sevenDayWindow。
    var snapshot: UsageSnapshot?
    /// 合并了刷新结果和实时额度的 5 小时窗口；两边都没有数据时为 nil
    var fiveHourWindow: ObservedWindow?
    /// 合并了刷新结果和实时额度的"全部模型"周窗口
    var sevenDayWindow: ObservedWindow?
    /// 最近一次刷新失败的原因；最近一次成功时为 nil
    var problem: UsageProblem?
    /// 频率限制：这个时间之前不再请求这个账号；没有限制时为 nil
    var retryAt: Date?

    /// 给了 snapshot 时，两个主窗口取自它（相当于只刷新过一次、没有实时额度）
    init(snapshot: UsageSnapshot? = nil, problem: UsageProblem? = nil, retryAt: Date? = nil) {
        self.snapshot = snapshot
        self.problem = problem
        self.retryAt = retryAt
        if let snapshot { merge(refresh: snapshot) }
    }

    /// 5 小时窗口此刻怎么显示；nil 表示不显示这一行（没有数据，或 utilization 为 null）
    func fiveHour(now: Date) -> UsageReading? { reading(fiveHourWindow, now: now) }

    /// "全部模型"周窗口此刻怎么显示；nil 表示不显示这一行
    func sevenDay(now: Date) -> UsageReading? { reading(sevenDayWindow, now: now) }

    /// 最近一次拿到数据的时间（刷新的获取时间、主窗口的观察时间里最晚的）；什么数据都没有时为 nil
    var updatedAt: Date? {
        [snapshot?.fetchedAt, fiveHourWindow?.observedAt, sevenDayWindow?.observedAt].compactMap { $0 }.max()
    }

    /// 按模型细分的各个周窗口此刻怎么显示（过期、已重置、颜色同 UsageReading）；没有数据时为空
    func modelWeekly(now: Date) -> [ModelWeeklyReading] {
        guard let snapshot, problem != .unrecognizedFormat else { return [] }
        return snapshot.modelWeekly.map {
            ModelWeeklyReading(model: $0.model, reading: UsageReading($0.window, fetchedAt: snapshot.fetchedAt, now: now),
                               resetsAt: $0.window.resetsAt)
        }
    }

    /// 超额付费此刻怎么显示：数据超过 30 分钟变灰；没有数据、接口没给、或格式无法识别时为 nil
    func extraUsage(now: Date) -> ExtraUsageReading? {
        guard let snapshot, problem != .unrecognizedFormat, let extra = snapshot.extraUsage else { return nil }
        return ExtraUsageReading(usage: extra,
                                 tint: UsageReading.isStale(fetchedAt: snapshot.fetchedAt, now: now) ? .stale : .plain)
    }

    /// 是否还在频率限制的等待期内（这期间不请求这个账号，刷新按钮不可用）
    func isWaiting(now: Date) -> Bool { waitRemaining(now: now) != nil }

    /// 还要等多少秒；不用等时为 nil
    func waitRemaining(now: Date) -> TimeInterval? {
        guard let retryAt, retryAt > now else { return nil }
        return retryAt.timeIntervalSince(now)
    }

    /// 变灰按这个窗口自己的观察时间算。没有数据时：格式无法识别显示"—"，否则不显示
    private func reading(_ window: ObservedWindow?, now: Date) -> UsageReading? {
        guard let window else { return problem == .unrecognizedFormat ? .unavailable : nil }
        return UsageReading(window.window, fetchedAt: window.observedAt, now: now)
    }

    /// 并入一次成功的刷新。刷新没给某个窗口（utilization 为 null）时，丢掉之前来自刷新的数值（与接入实时额度前
    /// 一样不显示），来自实时额度的保留。
    mutating func merge(refresh snapshot: UsageSnapshot) {
        fiveHourWindow = Self.merge(fiveHourWindow, snapshot.fiveHour, at: snapshot.fetchedAt, from: .refresh)
        sevenDayWindow = Self.merge(sevenDayWindow, snapshot.sevenDay, at: snapshot.fetchedAt, from: .refresh)
    }

    /// 并入一份实时额度；状态栏没给的窗口不动
    mutating func merge(live quota: LiveQuota) {
        if let window = quota.fiveHour {
            fiveHourWindow = fiveHourWindow.merging(ObservedWindow(window: window, observedAt: quota.receivedAt,
                                                                   source: .live))
        }
        if let window = quota.sevenDay {
            sevenDayWindow = sevenDayWindow.merging(ObservedWindow(window: window, observedAt: quota.receivedAt,
                                                                   source: .live))
        }
    }

    /// 格式无法识别：丢掉来自刷新的数值（接口可能已变化，旧数字不可信），实时额度另有来源，保留
    mutating func dropRefreshWindows() {
        if fiveHourWindow?.source == .refresh { fiveHourWindow = nil }
        if sevenDayWindow?.source == .refresh { sevenDayWindow = nil }
    }

    private static func merge(_ current: ObservedWindow?, _ window: UsageWindow?, at time: Date,
                              from source: ObservedWindow.Source) -> ObservedWindow? {
        guard let window else { return current?.source == source ? nil : current }
        return current.merging(ObservedWindow(window: window, observedAt: time, source: source))
    }
}

struct UsageBoard: Equatable {
    private var accounts: [UsageAccount: AccountUsage] = [:]
    /// 实时额度：每个档案上次并入时的账号，以及只并入这个时刻之后写的文件（见文件头）
    private var liveOwners: [String: LiveOwner] = [:]

    private struct LiveOwner: Equatable {
        let account: UsageAccount
        let since: Date?
    }

    init() {}

    /// 保存一次刷新的结果
    mutating func record(_ outcome: UsageRefreshOutcome) {
        var usage = accounts[outcome.account] ?? AccountUsage()
        usage.retryAt = nil
        switch outcome.result {
        case .success(let snapshot):
            usage.snapshot = snapshot
            usage.merge(refresh: snapshot)
            usage.problem = nil
        case .denied(let status), .unauthorized(let status):
            usage.problem = .login(status)
        case .rateLimited(let until):
            usage.problem = .rateLimited
            usage.retryAt = until
        case .httpStatus(let code):
            usage.problem = .httpStatus(code)
        case .networkFailure:
            usage.problem = .networkFailure
        case .unrecognizedFormat:
            usage.snapshot = nil
            usage.dropRefreshWindows()
            usage.problem = .unrecognizedFormat
        }
        accounts[outcome.account] = usage
    }

    /// 并入实时额度（LiveQuotaFiles.readAll() 的结果）：按档案名在 profiles 里找到账号，并入它的两个主窗口。
    /// 找不到档案、或档案未登录的跳过；档案换了登录时，换之前写的文件跳过（见文件头，now 是发现换登录的时刻）。
    /// 不改失败原因和频率限制等待时间，不发请求。
    /// 同一份文件重复并入不改变结果（合并规则对重复数据是幂等的），所以每次文件变化时把全部文件重新并入即可。
    mutating func recordLive(_ quotas: [LiveQuota], profiles: [Profile], now: Date = Date()) {
        for profile in profiles {
            guard let account = profile.usageAccount else { continue }
            if let owner = liveOwners[profile.name] {
                if owner.account != account { liveOwners[profile.name] = LiveOwner(account: account, since: now) }
            } else {
                liveOwners[profile.name] = LiveOwner(account: account, since: nil)
            }
        }
        for quota in quotas {
            guard let account = profiles.first(where: { $0.name == quota.profile })?.usageAccount else { continue }
            if let since = liveOwners[quota.profile]?.since, quota.receivedAt <= since { continue }
            var usage = accounts[account] ?? AccountUsage()
            usage.merge(live: quota)
            accounts[account] = usage
        }
    }

    /// 这个档案所在账号的额度状态；还没有数据、或档案未登录时为 nil
    func usage(for profile: Profile) -> AccountUsage? {
        profile.usageAccount.flatMap { usage(for: $0) }
    }

    /// 这个账号的额度状态（刷新结果与实时额度合并后）；还没有数据时为 nil。
    /// 窗口 Token 用量（ticket 03）用 fiveHourWindow / sevenDayWindow 的 resetsAt 对齐窗口。
    func usage(for account: UsageAccount) -> AccountUsage? {
        accounts[account]
    }

    /// 最近一次成功获取的额度
    func snapshot(for profile: Profile) -> UsageSnapshot? {
        usage(for: profile)?.snapshot
    }

    /// 去掉还在频率限制等待期内的账号，其余按原顺序返回
    func accountsAllowedToRefresh(_ list: [UsageAccount], now: Date) -> [UsageAccount] {
        list.filter { accounts[$0]?.isWaiting(now: now) != true }
    }

    /// 菜单栏两行：当前档案名与订阅等级，以及它所在账号的 5 小时窗口此刻怎么显示。
    /// 当前档案不在列表里、未登录、还没刷新过、或 5 小时窗口没有数字时，第二行是"—"。
    func menuBarSummary(currentProfile name: String, profiles: [Profile], now: Date) -> MenuBarSummary {
        let profile = profiles.first { $0.name == name }
        let reading = profile.flatMap { usage(for: $0) }?.fiveHour(now: now)
        return MenuBarSummary(profileName: name, fiveHour: reading ?? .unavailable, tier: profile?.displayTier)
    }
}
