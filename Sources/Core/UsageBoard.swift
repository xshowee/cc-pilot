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
//   格式无法识别                        → 丢掉旧数据，两个窗口都显示"—"（接口可能已变化）
//   成功                                → 替换数据，清除原因和等待时间

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

/// 一个账号的额度状态
struct AccountUsage: Equatable {
    /// 最近一次成功获取的数据（含获取时间）；从没成功过、或之后格式无法识别时为 nil
    var snapshot: UsageSnapshot?
    /// 最近一次刷新失败的原因；最近一次成功时为 nil
    var problem: UsageProblem?
    /// 频率限制：这个时间之前不再请求这个账号；没有限制时为 nil
    var retryAt: Date?

    /// 5 小时窗口此刻怎么显示；nil 表示不显示这一行（没有数据，或 utilization 为 null）
    func fiveHour(now: Date) -> UsageReading? { reading(snapshot?.fiveHour, now: now) }

    /// "全部模型"周窗口此刻怎么显示；nil 表示不显示这一行
    func sevenDay(now: Date) -> UsageReading? { reading(snapshot?.sevenDay, now: now) }

    /// 是否还在频率限制的等待期内（这期间不请求这个账号，刷新按钮不可用）
    func isWaiting(now: Date) -> Bool { waitRemaining(now: now) != nil }

    /// 还要等多少秒；不用等时为 nil
    func waitRemaining(now: Date) -> TimeInterval? {
        guard let retryAt, retryAt > now else { return nil }
        return retryAt.timeIntervalSince(now)
    }

    /// 格式无法识别时一律"—"（不显示旧数字）；没有数据或没有这个窗口时不显示
    private func reading(_ window: UsageWindow?, now: Date) -> UsageReading? {
        if problem == .unrecognizedFormat { return .unavailable }
        guard let snapshot, let window else { return nil }
        return UsageReading(window, fetchedAt: snapshot.fetchedAt, now: now)
    }
}

struct UsageBoard: Equatable {
    private var accounts: [UsageAccount: AccountUsage] = [:]

    init() {}

    /// 保存一次刷新的结果
    mutating func record(_ outcome: UsageRefreshOutcome) {
        var usage = accounts[outcome.account] ?? AccountUsage()
        usage.retryAt = nil
        switch outcome.result {
        case .success(let snapshot):
            usage.snapshot = snapshot
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
            usage.problem = .unrecognizedFormat
        }
        accounts[outcome.account] = usage
    }

    /// 这个档案所在账号的额度状态；还没刷新过、或档案未登录时为 nil
    func usage(for profile: Profile) -> AccountUsage? {
        profile.usageAccount.flatMap { accounts[$0] }
    }

    /// 最近一次成功获取的额度
    func snapshot(for profile: Profile) -> UsageSnapshot? {
        usage(for: profile)?.snapshot
    }

    /// 去掉还在频率限制等待期内的账号，其余按原顺序返回
    func accountsAllowedToRefresh(_ list: [UsageAccount], now: Date) -> [UsageAccount] {
        list.filter { accounts[$0]?.isWaiting(now: now) != true }
    }

    /// 菜单栏两行：当前档案名，以及它所在账号的 5 小时窗口此刻怎么显示。
    /// 当前档案不在列表里、未登录、还没刷新过、或 5 小时窗口没有数字时，第二行是"—"。
    func menuBarSummary(currentProfile name: String, profiles: [Profile], now: Date) -> MenuBarSummary {
        let reading = profiles.first { $0.name == name }
            .flatMap { usage(for: $0) }?.fiveHour(now: now)
        return MenuBarSummary(profileName: name, fiveHour: reading ?? .unavailable)
    }
}
