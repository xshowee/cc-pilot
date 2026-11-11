// 额度的界面状态：保存已获取的额度（App 核心 UsageBoard），响应"刷新全部"和单个账号的刷新按钮。
//
// 只有用户点击刷新时才调用 UsageRefresher 发请求；打开面板、启动 App、切换档案、重载档案列表
// 都只读 board，不发请求（与 ProfileListModel 的重载互不牵连）。请求在后台串行队列上逐个进行，
// 每完成一个账号就在主线程发布一次结果。还在频率限制等待期内的账号不请求（UsageBoard 判定）。
//
// 实时额度（token-usage ticket 05）：启动时读一次实时额度文件，之后 ProfileChangeFeed 报告实时额度目录有变化时
// 重读（读文件在后台队列上做），按当前档案列表找到账号并入 board；档案列表变化（登录、换账号）时用已读到的
// 文件重新并入。这条路径只读本地文件，不发请求，也不碰刷新的状态（UsageBoard.recordLive）。
//
// ChatGPT（chatgpt-profiles ticket 07）：额度记在同一个 board 里（账号键带 "chatgpt:" 前缀，不与 Claude 相撞），
// 由 ChatGPTUsageRefresher 刷新，同一个后台队列逐个账号进行；"刷新全部"同时刷新两段。
// 响应里的套餐（plan_type）按账号记在 reportedPlans，ChatGPT 行用它更新套餐标记。
//
// ChatGPT 实时额度（chatgpt-profiles ticket 08）：ChatGPT 会话记录的唯一读取器与监视器由 Token 用量记录器带着
// （AppDelegate 里的 TokenUsageRecorder，ticket 09：同一次扫描先记账再算实时额度），ChatGPTLiveQuotaTracker 把
// 进行中会话的 rate_limits 归属到账号，经 chatgptLiveQuotaDidUpdate 通知在主线程按账号并入 board
// （UsageBoard.recordLive(_:for:)）。同样只读本地文件，不发请求，不碰刷新的状态。
//
// Kimi Code（ADR 0007）：只显示额度，每个账号（名称 + API key）一个键（KimiUsageRefresher.account(名称)），
// 记在同一个 board 里，由 KimiUsageRefresher 在同一个后台队列上刷新；"刷新全部"也刷新它们。没有实时额度。
// 添加、删除账号时 forgetKimi(名称)：忘掉旧数字，并作废还没回来的刷新结果（那是旧 key 的）。
// 刷新 Kimi Code 账号时顺带请求它的模型列表和 /me（KimiUsageRefresher.refreshAccount，见 KimiModels.swift、
// KimiAccountInfo.swift），按账号名称记在 kimiModels、kimiAccounts（只在内存里，失败时保留上一次的），
// 侧边面板显示模型列表，卡片显示套餐名和"与某某是同一账号"；forgetKimi 时一起忘掉。
//
// now 是界面用的时钟：每 15 秒前进一次，只用来重算"N 分钟前获取"、变灰、已重置、还要等多久，
// 让菜单栏和面板随时间更新；它不触发任何请求。拿到新数据时 now 也会拨到此刻。

import Combine
import Foundation
import SwiftUI

extension Notification.Name {
    /// ChatGPT 实时额度（在主线程上发出）；userInfo[chatgptLiveQuotaKey] 是 [UsageAccount: LiveQuota]
    static let chatgptLiveQuotaDidUpdate = Notification.Name("CCPilotChatGPTLiveQuotaDidUpdate")
}

/// chatgptLiveQuotaDidUpdate 的 userInfo 键
let chatgptLiveQuotaKey = "quotas"

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var board = UsageBoard()
    /// 正在刷新的账号
    @Published private(set) var refreshing: Set<UsageAccount> = []
    /// 界面时钟（见文件头）
    @Published private(set) var now = Date()
    /// ChatGPT 账号最近一次成功刷新时响应里的套餐（plan_type 原样）；响应没给或邮箱对不上时没有
    @Published private(set) var reportedPlans: [UsageAccount: String] = [:]
    /// Kimi Code 账号（按名称）的模型列表；还没刷新过的账号没有
    @Published private(set) var kimiModels: [String: KimiModelList] = [:]
    /// Kimi Code 账号（按名称）最近一次成功获取的套餐名和用户标识；还没成功过的账号没有
    @Published private(set) var kimiAccounts: [String: KimiAccountInfo] = [:]

    private let refresher: UsageRefresher
    private let chatgptRefresher: ChatGPTUsageRefresher
    private let kimiRefresher: KimiUsageRefresher
    /// 各 Kimi Code 账号名称 forgetKimi 的次数：刷新结果回来时与发出时不同，说明 key 已经换过，结果作废
    private var kimiGenerations: [String: Int] = [:]
    private let queue = DispatchQueue(label: "com.ccpilot.usage-refresh", qos: .userInitiated)
    private var clock: AnyCancellable?

    private let liveFiles: LiveQuotaFiles
    private let liveQueue = DispatchQueue(label: "com.ccpilot.live-quota", qos: .userInitiated)
    /// 最近一次读到的实时额度文件
    private var liveQuotas: [LiveQuota] = []
    /// 并入实时额度时用来按档案找账号的档案列表（见 follow(profiles:)）
    private var profiles: [Profile] = []
    private var profilesSubscription: AnyCancellable?
    private var liveGeneration = 0
    private var chatgptLiveObserver: NSObjectProtocol?

    init(environment: CoreEnvironment = .live, changes: ProfileChangeFeed) {
        refresher = UsageRefresher(environment: environment)
        chatgptRefresher = ChatGPTUsageRefresher(environment: environment)
        kimiRefresher = KimiUsageRefresher(environment: environment)
        liveFiles = LiveQuotaFiles(environment: environment)
        clock = Timer.publish(every: 15, tolerance: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in self?.now = date }
        changes.subscribeLiveQuota { [weak self] in self?.reloadLiveQuota() }
        // 文件监听只报告之后的变化，App 启动前写下的文件要先读一次
        reloadLiveQuota()
        chatgptLiveObserver = NotificationCenter.default.addObserver(
            forName: .chatgptLiveQuotaDidUpdate, object: nil, queue: .main) { [weak self] note in
            guard let quotas = note.userInfo?[chatgptLiveQuotaKey] as? [UsageAccount: LiveQuota] else { return }
            Task { @MainActor in self?.applyChatGPTLiveQuota(quotas) }
        }
    }

    /// 并入 ChatGPT 实时额度；board 没变时不发布
    private func applyChatGPTLiveQuota(_ quotas: [UsageAccount: LiveQuota]) {
        var updated = board
        for (account, quota) in quotas { updated.recordLive(quota, for: account) }
        guard updated != board else { return }
        board = updated
        now = Date()
    }

    /// 跟随档案列表：列表变化时把已读到的实时额度按新的档案—账号对应重新并入
    func follow(profiles publisher: Published<[Profile]>.Publisher) {
        profilesSubscription = publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] list in
                guard let self else { return }
                self.profiles = list
                self.applyLiveQuota()
            }
    }

    /// 在后台重读全部实时额度文件；连续调用时只采用最后一次的结果
    private func reloadLiveQuota() {
        liveGeneration += 1
        let request = liveGeneration
        let files = liveFiles
        liveQueue.async { [weak self] in
            let quotas = files.readAll()
            Task { @MainActor in
                guard let self, request == self.liveGeneration else { return }
                self.liveQuotas = quotas
                self.applyLiveQuota()
            }
        }
    }

    /// 并入实时额度（同一批文件重复并入不改变结果）。还没有文件时也调用：board 要记下各档案此刻的账号，
    /// 之后才认得出换登录。board 没变时不发布（状态栏每次重绘都会重写文件），免得界面和统计面板白白重算。
    private func applyLiveQuota() {
        guard !profiles.isEmpty else { return }
        var updated = board
        updated.recordLive(liveQuotas, profiles: profiles, now: Date())
        guard updated != board else { return }
        board = updated
        now = Date()
    }

    var isRefreshing: Bool { !refreshing.isEmpty }

    func isRefreshing(_ profile: Profile) -> Bool {
        profile.usageAccount.map(refreshing.contains) ?? false
    }

    /// 这个档案所在账号的额度状态
    func usage(for profile: Profile) -> AccountUsage? {
        board.usage(for: profile)
    }

    /// 是否还在频率限制的等待期内（刷新按钮不可用）
    func isWaiting(_ profile: Profile) -> Bool {
        usage(for: profile)?.isWaiting(now: now) ?? false
    }

    func isRefreshing(_ profile: ChatGPTProfile) -> Bool {
        profile.usageAccount.map(refreshing.contains) ?? false
    }

    /// 这个 ChatGPT 档案所在账号的额度状态
    func usage(for profile: ChatGPTProfile) -> AccountUsage? {
        board.usage(for: profile)
    }

    /// 这个 ChatGPT 档案所在账号最近一次刷新时响应里的套餐
    func reportedPlan(for profile: ChatGPTProfile) -> String? {
        profile.usageAccount.flatMap { reportedPlans[$0] }
    }

    /// 这个 Kimi Code 账号的额度状态；还没刷新过时为 nil
    func kimiUsage(_ name: String) -> AccountUsage? { board.usage(for: KimiUsageRefresher.account(name)) }

    func isRefreshingKimi(_ name: String) -> Bool { refreshing.contains(KimiUsageRefresher.account(name)) }

    /// 刷新这个 Kimi Code 账号的额度
    func refreshKimi(_ name: String) {
        start([kimiJob(name)])
    }

    /// 添加、删除 Kimi Code 账号时：忘掉这个名称的额度，还没回来的刷新结果作废
    func forgetKimi(_ name: String) {
        kimiGenerations[name, default: 0] += 1
        board.forget(KimiUsageRefresher.account(name))
        kimiModels[name] = nil
        kimiAccounts[name] = nil
    }

    /// "刷新全部"现在能否点：各段里有不在等待期、也没在刷新的账号。kimi：Kimi Code 账号的名称
    func canRefreshAny(_ profiles: [Profile], chatgpt: [ChatGPTProfile] = [], kimi: [String] = []) -> Bool {
        !pending(UsageRefresher.accounts(in: profiles) + ChatGPTUsageRefresher.accounts(in: chatgpt)
                 + kimi.map(KimiUsageRefresher.account)).isEmpty
    }

    /// "刷新全部"：各段里每个账号请求一次（正在刷新、还在等待期内的账号跳过）
    func refreshAll(_ profiles: [Profile], chatgpt: [ChatGPTProfile] = [], kimi: [String] = []) {
        start(UsageRefresher.accounts(in: profiles).map { claudeJob($0, profiles) }
              + ChatGPTUsageRefresher.accounts(in: chatgpt).map { chatgptJob($0, chatgpt) }
              + kimi.map(kimiJob))
    }

    /// 刷新这个档案所在的账号
    func refresh(_ profile: Profile, in profiles: [Profile]) {
        guard let account = profile.usageAccount else { return }
        start([claudeJob(account, profiles)])
    }

    /// 刷新这个 ChatGPT 档案所在的账号
    func refresh(_ profile: ChatGPTProfile, in profiles: [ChatGPTProfile]) {
        guard let account = profile.usageAccount else { return }
        start([chatgptJob(account, profiles)])
    }

    /// 一个账号的刷新：在后台队列上执行 fetch，结果回到主线程交给 apply
    private struct Job {
        let account: UsageAccount
        /// Kimi Code 的刷新：账号名称与发出时的 kimiGenerations[名称]；其他为 nil
        var kimi: (name: String, generation: Int)? = nil
        let fetch: () -> RefreshResult
    }

    private struct RefreshResult {
        let outcome: UsageRefreshOutcome
        /// ChatGPT 的响应套餐；Claude 为 nil
        let reported: ChatGPTReportedAccount?
        /// Kimi Code 的模型列表、/me；没有请求时为 nil
        var kimiModels: KimiModelsFetchResult? = nil
        var kimiAccount: KimiAccountFetchResult? = nil
    }

    private func claudeJob(_ account: UsageAccount, _ profiles: [Profile]) -> Job {
        let refresher = refresher
        return Job(account: account) {
            RefreshResult(outcome: refresher.refresh(account, in: profiles, now: Date()), reported: nil)
        }
    }

    private func chatgptJob(_ account: UsageAccount, _ profiles: [ChatGPTProfile]) -> Job {
        let refresher = chatgptRefresher
        return Job(account: account) {
            let result = refresher.refresh(account, in: profiles, now: Date())
            return RefreshResult(outcome: result.outcome, reported: result.reported)
        }
    }

    private func kimiJob(_ name: String) -> Job {
        let refresher = kimiRefresher
        return Job(account: KimiUsageRefresher.account(name), kimi: (name, kimiGenerations[name, default: 0])) {
            let result = refresher.refreshAccount(name, now: Date())
            return RefreshResult(outcome: result.usage, reported: nil, kimiModels: result.models,
                                 kimiAccount: result.account)
        }
    }

    private func pending(_ accounts: [UsageAccount]) -> [UsageAccount] {
        board.accountsAllowedToRefresh(accounts, now: Date()).filter { !refreshing.contains($0) }
    }

    private func start(_ jobs: [Job]) {
        let allowed = Set(pending(jobs.map(\.account)))
        let pending = jobs.filter { allowed.contains($0.account) }
        guard !pending.isEmpty else { return }
        now = Date()
        refreshing.formUnion(pending.map(\.account))
        queue.async { [weak self] in
            for job in pending {
                let result = job.fetch()
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshing.remove(job.account)
                    self.now = Date()
                    // 发出之后换过 key：这是旧 key 的结果，不记
                    if let kimi = job.kimi, kimi.generation != self.kimiGenerations[kimi.name, default: 0] { return }
                    if let kimi = job.kimi {
                        // 只有刷新这一个来源：成功就替换，不合并（见 UsageBoard.recordReplacing）
                        self.board.recordReplacing(result.outcome)
                        if let models = result.kimiModels {
                            self.kimiModels[kimi.name, default: KimiModelList()].record(models, at: Date())
                        }
                        if case .success(let info)? = result.kimiAccount { self.kimiAccounts[kimi.name] = info }
                    } else {
                        self.board.record(result.outcome)
                    }
                    if let reported = result.reported { self.reportedPlans[job.account] = reported.planType }
                }
            }
        }
    }
}
