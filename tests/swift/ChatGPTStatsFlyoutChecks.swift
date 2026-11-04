// chatgpt-profiles ticket 10：鼠标停在 ChatGPT 账号行上时弹出的统计面板（复用 Claude 的面板）。
//
// 检查的接口（seam）：
//   StatsFlyoutTarget(chatgpt:)                       ChatGPT 档案行 → 显示哪个账号
//   StatsFlyoutRow.rows(claudeCode:chatgpt:)、StatsFlyoutHover   行按"工具 + 档案名"区分（两个工具可以有同名档案）
//   KnownResets(usage: board.usage(for: ChatGPTProfile)) + TokenUsageRecorder.accountUsage
//                                                     面板的窗口与累计数字（界面就是这样取的，见 StatsFlyoutRoot）
//   TokenUsageRecorder.clearCumulative / clearAllCumulative   清空
// 会话记录是合成的（CodexRolloutFixtures），归属直接写进账本（归属规则由 ChatGPTSessionAttributionChecks 检查）。
// 期望值手算：窗口规则同 token-usage spec 决策 4，四类映射同 chatgpt-profiles spec（输入 = input − cached）。

import Foundation

final class ChatGPTStatsFlyoutChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("ChatGPT 档案行显示它所在账号：同一账号的两个档案显示同一份；未登录、API key 没有面板", targets),
            Check("两个工具的同名档案是不同的行：悬停、收起互不串", sameNameAcrossTools),
            Check("ChatGPT 账号的窗口对齐它自己的额度窗口；累计从最早一条起；四类与按模型；不含未归属和别的账号",
                  windowsAndCumulative),
            Check("清空单个 ChatGPT 账号只影响它的累计；清空全部账号也清 ChatGPT 账号；清空后通知界面", clears),
        ]
    }

    typealias A = ChatGPTSessionAttributionChecks

    // MARK: - 哪一行显示哪个账号

    static func targets() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault(auth: chatgptAuth(email: "d@example.com", userID: "user-d", workspaceID: "ws-1"))
        try home.makeCodexProfile("work", auth: chatgptAuth(email: "w@example.com", userID: "user-w", workspaceID: "ws-1"))
        try home.makeCodexProfile("work2", auth: chatgptAuth(email: "w@example.com", userID: "user-w", workspaceID: "ws-1"))
        try home.makeCodexProfile("keyed", auth: apiKeyAuth())
        try home.makeCodexProfile("empty")
        let profiles = ChatGPTProfileStore(environment: home.environment).listProfiles(now: fixedNow)
        func target(_ name: String) throws -> StatsFlyoutTarget? {
            StatsFlyoutTarget(chatgpt: try unwrap(profiles.first { $0.name == name }, "没有档案 \(name)"))
        }

        let work = try unwrap(try target("work")), work2 = try unwrap(try target("work2"))
        let defaultTarget = try unwrap(try target("default"))
        try expectEqual(work.account.id, "chatgpt:user-w:ws-1", "与账本记的账号一致")
        try expectEqual(work.email, "w@example.com")
        try expectEqual(work2.account, work.account, "同一账号")
        try expect(defaultTarget.account != work.account, "同一工作区的不同用户是不同账号")
        try expect(try target("keyed") == nil, "API key 没有面板")
        try expect(try target("empty") == nil, "未登录没有面板")
    }

    // MARK: - 同名档案

    static func sameNameAcrossTools() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.makeCodexDefault(auth: chatgptAuth(email: "d@example.com", userID: "user-d", workspaceID: "ws-1"))
        try home.makeCodexProfile("work", auth: chatgptAuth(email: "w@example.com", userID: "user-w", workspaceID: "ws-1"))
        try home.makeCodexProfile("empty")
        let chatgpt = ChatGPTProfileStore(environment: home.environment).listProfiles(now: fixedNow)
        let claude = [LiveQuotaMergeChecks.profile("work", uuid: "u-1"),
                      Profile(name: "empty", configDir: "/nonexistent/empty",
                              claudeJSON: URL(fileURLWithPath: "/nonexistent/empty.json"), account: .loggedOut)]

        let claudeWork = StatsFlyoutRow(tool: .claudeCode, name: "work")
        let chatgptWork = StatsFlyoutRow(tool: .chatgpt, name: "work")
        let chatgptDefault = StatsFlyoutRow(tool: .chatgpt, name: "default")
        try expect(claudeWork != chatgptWork, "同名不同工具是不同的行")
        // 只报有账号的行（两边的 empty 都没登录）
        try expectEqual(StatsFlyoutRow.rows(claudeCode: claude, chatgpt: chatgpt),
                        [claudeWork, chatgptWork, chatgptDefault])

        var hover = StatsFlyoutHover()
        hover.row(chatgptWork, hovering: true)
        try expectEqual(hover.row, chatgptWork)
        // Claude 的 work 被删除：ChatGPT 的 work 照常显示
        hover.rowsChanged(StatsFlyoutRow.rows(claudeCode: [], chatgpt: chatgpt))
        try expectEqual(hover.row, chatgptWork, "另一个工具的同名档案没了不影响")
        // 离开的是 Claude 的 work（迟到的离开通知）：不当成离开了 ChatGPT 的 work
        hover.row(claudeWork, hovering: false)
        hover.settle()
        try expectEqual(hover.row, chatgptWork, "另一个工具同名行的离开不算")
        // ChatGPT 的 work 登出：收起
        hover.rowsChanged(StatsFlyoutRow.rows(claudeCode: claude, chatgpt: chatgpt.filter { $0.name != "work" }))
        try expectEqual(hover.row, nil)
    }

    // MARK: - 数字

    static let work = A.workAccount
    static let defaultAccount = A.defaultAccount
    static let workSession = "019a4f00-0000-7000-8000-0000000010a1"
    static let defaultSession = "019a4f00-0000-7000-8000-0000000010b2"
    static let unknownSession = "019a4f00-0000-7000-8000-0000000010c3"
    /// 面板打开的时刻：2026-11-04T13:00:00Z
    static let now = A.at(180)

    static func iso(_ minutes: Double) -> String { A.iso(A.at(minutes)) }

    /// work 账号（user-w）四次用量：10 天前、−90 分钟、30 分钟、60 分钟（中途换模型）；
    /// default 账号、未归属会话各一次（都在当前窗口里，面板都不该算）
    static func seed(_ env: A.Env) throws {
        let tenDaysAgo = -10 * 1440.0
        try env.home.write(CodexRollout.path(workSession), CodexRollout.file([
            CodexRollout.meta(id: workSession, at: iso(tenDaysAgo), creatorUserID: "user-w"),
            CodexRollout.turnContext(model: "gpt-5.1-codex-max", at: iso(tenDaysAgo)),
            CodexRollout.tokenCount(at: iso(tenDaysAgo), last: .init(input: 1000, output: 100),
                                    total: .init(input: 1000, output: 100)),
            CodexRollout.turnContext(model: "gpt-5.3-codex", at: iso(-90)),
            CodexRollout.tokenCount(at: iso(-90), last: .init(input: 300, cached: 200, output: 30),
                                    total: .init(input: 1300, cached: 200, output: 130)),
            CodexRollout.tokenCount(at: iso(30), last: .init(input: 50, output: 5, cacheWrite: 7),
                                    total: .init(input: 1350, cached: 200, output: 135, cacheWrite: 7)),
            CodexRollout.turnContext(model: "gpt-5.1-codex-max", at: iso(55)),
            CodexRollout.tokenCount(at: iso(60), last: .init(input: 20, cached: 10, output: 2),
                                    total: .init(input: 1370, cached: 210, output: 137, cacheWrite: 7)),
        ]))
        for (id, input) in [(defaultSession, 7777), (unknownSession, 9999)] {
            try env.home.write(CodexRollout.path(id), CodexRollout.file([
                CodexRollout.meta(id: id, at: iso(40)),
                CodexRollout.turnContext(model: "gpt-5.3-codex", at: iso(40)),
                CodexRollout.tokenCount(at: iso(40), last: .init(input: input, output: 1)),
            ]))
        }
        try env.ingest()
        try env.ledger.attribute(sessionID: workSession, as: .attributed(profile: "work", account: work), tool: .chatgpt)
        try env.ledger.attribute(sessionID: defaultSession, as: .attributed(profile: "default", account: defaultAccount),
                                 tool: .chatgpt)
        try env.ledger.attribute(sessionID: unknownSession, as: .unattributed, tool: .chatgpt)
    }

    static func recorder(_ env: A.Env, updates: ProfileWatcherChecks.Counter? = nil) -> TokenUsageRecorder {
        TokenUsageRecorder(environment: env.home.environment, latency: 0.05,
                           calendar: TokenLedgerRollupChecks.calendar, now: { now }, attribute: { _ in },
                           onUpdate: { updates?.increment() })
    }

    /// 面板取数字的方式（StatsFlyoutRoot）：档案 → 账号 → 看板上它的额度 → resets_at → 账本
    static func panelUsage(_ env: A.Env, _ recorder: TokenUsageRecorder, board: UsageBoard,
                           profile name: String) throws -> AccountTokenUsage {
        let profiles = ChatGPTProfileStore(environment: env.home.environment).listProfiles(now: now)
        let profile = try unwrap(profiles.first { $0.name == name })
        let target = try unwrap(StatsFlyoutTarget(chatgpt: profile))
        return try recorder.accountUsage(target.account.id, resets: KnownResets(usage: board.usage(for: profile)))
    }

    static func windowsAndCumulative() throws {
        let env = try A.Env()
        defer { env.remove() }
        try seed(env)
        let recorder = recorder(env)

        // work 账号的额度：5 小时窗口 14:00 重置（从 09:00 起），周窗口两天后重置（从 5 天前起）
        var board = UsageBoard()
        let weekResets = A.at(2 * 1440)
        board.recordLive(LiveQuota(profile: "work", receivedAt: A.at(170),
                                   fiveHour: UsageWindow(utilization: 40, resetsAt: A.at(240)),
                                   sevenDay: UsageWindow(utilization: 10, resetsAt: weekResets)),
                         for: UsageAccount(id: work))

        let usage = try panelUsage(env, recorder, board: board, profile: "work")
        try expectEqual(usage.fiveHour.start, A.at(-60), "5 小时窗口 = resets_at − 5h 起")
        try expectEqual(usage.fiveHour.end, A.at(240))
        try expectEqual(usage.sevenDay.start, A.at(2 * 1440 - 7 * 1440), "周窗口 = resets_at − 7d 起")
        // 30 分钟：输入 50、输出 5、缓存写入 7；60 分钟：输入 20 − 10、缓存读取 10、输出 2
        try expectEqual(usage.fiveHour.usage.tokens, TokenCounts(input: 60, output: 7, cacheWrite: 7, cacheRead: 10))
        try expectEqual(usage.fiveHour.usage.byModel.map { "\($0.model) \($0.tokens.total)" },
                        ["GPT-5.3-Codex 62", "GPT-5.1-Codex-Max 22"])
        // 加上 −90 分钟：输入 300 − 200、缓存读取 200、输出 30
        try expectEqual(usage.sevenDay.usage.tokens, TokenCounts(input: 160, output: 37, cacheWrite: 7, cacheRead: 210))
        // 再加上 10 天前：输入 1000、输出 100
        try expectEqual(usage.cumulative.origin, A.at(-10 * 1440), "起算点是最早一条记录")
        try expectEqual(usage.cumulative.usage.tokens, TokenCounts(input: 1160, output: 137, cacheWrite: 7, cacheRead: 210))
        try expectEqual(usage.hourly.map(\.tokens.total).reduce(0, +), 84 + 330, "24 小时历史含 −90 分钟那次")
        try expectEqual(usage.daily.map(\.tokens.total).reduce(0, +), 84 + 330 + 1100, "30 天历史")

        // 面板按 Core 算好的样子画
        let figure = TokenFigure(usage, period: .fiveHour)
        try expectEqual(figure.total, "84")
        try expectEqual(figure.models.map(\.name), ["GPT-5.3-Codex", "GPT-5.1-Codex-Max"])

        // 这个账号没拿到过额度：滚动窗口（现在往前 5 小时，含 −90 分钟那次）
        let rolling = try panelUsage(env, recorder, board: UsageBoard(), profile: "work")
        try expectEqual(rolling.fiveHour.start, now.addingTimeInterval(-5 * 3600))
        try expectEqual(rolling.fiveHour.usage.tokens.total, 84 + 330)

        // default 账号只有它自己那一次；未归属的 9999 哪个账号都不算
        let other = try panelUsage(env, recorder, board: board, profile: "default")
        try expectEqual(other.cumulative.usage.tokens, TokenCounts(input: 7777, output: 1, cacheWrite: 0, cacheRead: 0))
    }

    static func clears() throws {
        let env = try A.Env()
        defer { env.remove() }
        try seed(env)
        let updates = ProfileWatcherChecks.Counter()
        let recorder = recorder(env, updates: updates)
        let board = UsageBoard()
        let before = try panelUsage(env, recorder, board: board, profile: "work")

        try recorder.clearCumulative(account: work)
        try expectEqual(updates.count, 1, "清空后通知界面")
        let after = try panelUsage(env, recorder, board: board, profile: "work")
        try expectEqual(after.cumulative, TokenUsageCumulative(origin: now, usage: .empty), "累计归零，起算点是清空时刻")
        try expectEqual(after.fiveHour, before.fiveHour, "窗口不变")
        try expectEqual(after.sevenDay, before.sevenDay)
        try expectEqual(try panelUsage(env, recorder, board: board, profile: "default").cumulative.usage.tokens.total,
                        7778, "别的账号不受影响")

        try recorder.clearAllCumulative()
        try expectEqual(updates.count, 2)
        try expectEqual(try panelUsage(env, recorder, board: board, profile: "default").cumulative,
                        TokenUsageCumulative(origin: now, usage: .empty), "清空全部账号包括 ChatGPT 账号")
    }
}
