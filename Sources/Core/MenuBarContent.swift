// 菜单栏显示什么（chatgpt-profiles ticket 11，spec "菜单栏"）：
// - 两个工具都显示：每行一个工具，`[图标] <5 小时剩余>%`（Claude Code 在上、ChatGPT 在下），不显示套餐名；
//   每行的文字、颜色、"—"、"已重置"、变灰同原来的额度一行（UsageReading.menuBarText / menuBarTint）。
// - 只显示一个工具：保持原来的"套餐 / 5 小时剩余"两行（MenuBarSummary）。
// 一个工具显示 ⇔ 设置里没有隐藏它，且它有默认档案。Claude Code 一段总是存在（面板也总是显示它）；
// ChatGPT 没有默认档案 ~/.codex 时档案列表为空（ChatGPTProfileStore.listProfiles），不显示。
// 两个工具都不显示（都被隐藏，或隐藏了 Claude Code 而没有 ChatGPT 默认档案）时显示 Claude Code，不让菜单栏变空；
// 设置菜单也不允许把两个都关掉。"只显示图标"模式不经过这里（MenuBarLabel 直接画图标）。
//
// 额度取自额度看板里当前档案所在账号的 5 小时窗口（AccountUsage.fiveHour：刷新与实时额度合并后的数字）。
// ChatGPT 账号的键见 ChatGPTAccountKey.usageAccount；实时额度并入看板后菜单栏自然跟着变。

import Foundation

/// 设置里"菜单栏显示哪些工具"（UserDefaults，界面在 SettingsMenu）。默认两个都显示。
struct MenuBarToolPreferences: Equatable {
    var hidesClaudeCode = false
    var hidesChatGPT = false
}

/// 两个工具都显示时的一行：工具图标 + 当前档案的 5 小时剩余
struct MenuBarToolLine: Equatable {
    let tool: Tool
    /// 这个工具的当前档案名（悬停提示与读屏用）
    let profileName: String
    let fiveHour: UsageReading

    func quotaLine(resetText: String) -> String { fiveHour.menuBarText(resetText: resetText) }
    var quotaTint: UsageTint { fiveHour.menuBarTint }
}

enum MenuBarContent: Equatable {
    /// 只显示一个工具：套餐 / 5 小时剩余两行
    case single(MenuBarSummary)
    /// 两个工具：上一行 Claude Code，下一行 ChatGPT
    case twoTools(MenuBarToolLine, MenuBarToolLine)
}

extension UsageBoard {
    /// 菜单栏的内容（见文件头）。
    /// - claudeCode / profiles：Claude Code 当前档案名与档案列表
    /// - chatgpt / chatgptProfiles：ChatGPT 当前档案名与档案列表（没有默认档案时为空）
    /// - reportedPlans：最近一次刷新响应里的套餐（按账号，UsageModel.reportedPlans），比 auth.json 里的新
    func menuBarContent(claudeCode claudeName: String, profiles: [Profile],
                        chatgpt chatgptName: String, chatgptProfiles: [ChatGPTProfile],
                        reportedPlans: [UsageAccount: String],
                        preferences: MenuBarToolPreferences, now: Date) -> MenuBarContent {
        let showsChatGPT = !preferences.hidesChatGPT && !chatgptProfiles.isEmpty
        let showsClaudeCode = !preferences.hidesClaudeCode
        let claude = menuBarSummary(currentProfile: claudeName, profiles: profiles, now: now)
        guard showsChatGPT else { return .single(claude) }

        let profile = chatgptProfiles.first { $0.name == chatgptName }
        let reading = profile.flatMap { usage(for: $0) }?.fiveHour(now: now) ?? .unavailable
        guard showsClaudeCode else {
            let plan = profile.flatMap { $0.usageAccount.flatMap { reportedPlans[$0] } ?? $0.account?.planType }
            return .single(MenuBarSummary(profileName: chatgptName, fiveHour: reading, tool: .chatgpt,
                                          chatgptPlan: plan))
        }
        return .twoTools(MenuBarToolLine(tool: .claudeCode, profileName: claudeName, fiveHour: claude.fiveHour),
                         MenuBarToolLine(tool: .chatgpt, profileName: chatgptName, fiveHour: reading))
    }
}
