// 在 App 启动时就要存在、与面板是否打开无关的对象。
// MenuBarExtra 的面板内容在第一次打开时才构建，放在那里的对象不会在启动时创建；
// Sparkle 的每日定时检查必须从启动开始算，所以 Updater 放在这里；
// 安装/更新 ccp 和首次运行的接入引导也要在启动时进行（ticket 08）；
// Token 用量账本从启动起就跟着会话记录增量读入，并按各档案的 history.jsonl 归属到账号（token-usage ticket 01、02）；
// 统计面板（ticket 07）经 TokenStatsModel 读它，账本更新时收到 tokenUsageDidUpdate 通知。

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let updater = Updater()
    @MainActor let launchAtLogin = LaunchAtLoginModel()
    @MainActor let shellIntegration = ShellIntegrationModel()
    let tokenUsage = TokenUsageRecorder(environment: .live, onUpdate: {
        // 在账本队列上触发：只能异步回主线程（统计面板会在后台同步等账本队列，主线程不能反过来同步等它）
        DispatchQueue.main.async { NotificationCenter.default.post(name: .tokenUsageDidUpdate, object: nil) }
    })
    @MainActor lazy var tokenStats = TokenStatsModel(recorder: tokenUsage)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 放到下一轮主循环，等菜单栏图标出现后再弹出引导
        Task { @MainActor [shellIntegration] in shellIntegration.startup() }
        tokenUsage.start()
    }
}
