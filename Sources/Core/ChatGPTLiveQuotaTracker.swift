// ChatGPT 实时额度（chatgpt-profiles ticket 08，spec "实时额度"，ADR 0004 的做法用到 ChatGPT 上）：
// codex / 桌面 App 每次请求后把拿到的 rate_limits 写进会话记录的 token_count 事件；已归属到账号的最新一份
// 就是该账号的实时额度。只读本地文件，不发任何请求。
//
// 用法：会话记录读取器每读到新事件，交给 update(with:)，把返回的各账号实时额度交给 UsageBoard.recordLive(_:for:)
// （合并规则同 Claude：resets_at 更晚的优先，相同时取已用百分比高的；变灰按事件自己的时间算）。
//
// fork（及带历史的子代理）重放进新文件的父会话事件（CodexTokenCountEvent.replayed）不算：它们的 rate_limits 是
// 父会话当时的旧值（可能属于别的账号），时间戳却是重放时的，当作新鲜额度会盖住真实的数字。
// 认不出重放在哪里结束时（回合 ID 不是 UUIDv7，见 CodexSessionLog.swift），fork 自己的事件也一并不算——
// 宁可少一份实时额度，也不显示错误的数字。
//
// 归属：只认进行中的会话（ChatGPTSessionWriters：写它的进程的 CODEX_HOME → 档案）。写入者是外部目录、
// 找不到写入者、或档案没有可用的账号（未登录、API key、读不懂）时，这个会话不更新任何账号。
// 账号在归属时确定并记住：档案之后换了登录，运行中的进程仍在用旧账号的令牌，它写下的额度仍属于旧账号。
// 会话改由别的档案的进程写（共享会话被 resume）时重新确定。档案当时没有账号时不记住（auth.json 可能正写到一半，
// 或会话开始后才登录），之后每批事件重读，读到账号时再确定（同一批里每个档案只读一次）。
// 只在一个线程 / 串行队列上使用。

import Foundation

final class ChatGPTLiveQuotaTracker {
    private let store: ChatGPTProfileStore
    private let writers: ChatGPTSessionWriters
    /// 会话归属时确定的档案与账号（只记读到了账号的）
    private var owners: [String: (profile: String, account: UsageAccount)] = [:]

    init(environment: CoreEnvironment, writers: ChatGPTSessionWriters? = nil) {
        store = ChatGPTProfileStore(environment: environment)
        self.writers = writers ?? ChatGPTSessionWriters(environment: environment)
    }

    /// 并入新读到的事件；返回这批事件里有实时额度的各账号最新（事件时间最晚）的一份
    func update(with events: [CodexTokenCountEvent]) -> [UsageAccount: LiveQuota] {
        let limited = events.filter { $0.rateLimits != nil && !$0.replayed }
        guard !limited.isEmpty else { return [:] }
        let found = writers.writers(of: Set(limited.map(\.sessionID)))
        var latest: [UsageAccount: LiveQuota] = [:]
        // 这一批里各档案此刻的账号（同一批里不重复读 auth.json）
        var current: [String: UsageAccount?] = [:]
        for event in limited {
            guard case .profile(let name)? = found[event.sessionID], let limits = event.rateLimits,
                  let account = account(of: event.sessionID, profile: name, current: &current) else { continue }
            if let current = latest[account], current.receivedAt > event.timestamp { continue }
            latest[account] = LiveQuota(profile: name, receivedAt: event.timestamp,
                                        fiveHour: limits.fiveHour, sevenDay: limits.sevenDay)
        }
        return latest
    }

    /// 会话所属的账号：同一档案沿用归属时确定的账号，换了档案或还没确定时读档案此刻的账号
    private func account(of session: String, profile: String,
                         current: inout [String: UsageAccount?]) -> UsageAccount? {
        if let owner = owners[session], owner.profile == profile { return owner.account }
        let account: UsageAccount?
        if let cached = current[profile] {
            account = cached
        } else {
            account = store.profile(named: profile).usageAccount
            current[profile] = account
        }
        if let account { owners[session] = (profile, account) } else { owners[session] = nil }
        return account
    }
}
