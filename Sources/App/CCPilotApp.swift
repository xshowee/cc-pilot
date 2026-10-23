// App 入口。只负责把各部分组装起来；界面只调用 App 核心（Sources/Core），不自己读文件。
//
// 本目录（Sources/App）的约定：
// - 界面文字一律写英文原文，用 SwiftUI 的 Text("…") / Button("…") 或 String(localized: "…")，
//   中文翻译放在 Resources/zh-Hans.lproj/Localizable.strings（键就是英文原文，插值写成 %@ / %lld）。
// - 状态用 ObservableObject（目标系统 macOS 13，不能用 Observation）。
// - 一个视图一个文件，后续 ticket 新增功能时新增文件，尽量不改同一个文件。

import SwiftUI

@main
struct CCPilotApp: App {
    @StateObject private var profiles = ProfileListModel()
    @StateObject private var current = CurrentProfileModel()
    @StateObject private var usage = UsageModel()
    @AppStorage(MenuBarPreferences.iconOnlyKey) private var menuBarIconOnly = false
    // Sparkle、"登录时启动"与 ccp 的安装（见 AppDelegate.swift）
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PanelView(profiles: profiles, current: current, usage: usage)
                .environmentObject(appDelegate.updater)
                .environmentObject(appDelegate.launchAtLogin)
                .environmentObject(appDelegate.shellIntegration)
        } label: {
            MenuBarLabel(summary: usage.board.menuBarSummary(currentProfile: current.name, profiles: profiles.profiles),
                         iconOnly: menuBarIconOnly)
        }
        .menuBarExtraStyle(.window)
    }
}
