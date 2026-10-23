// 封装 Sparkle：面板里的"检查更新…"、"自动检查更新"开关与后台每天一次的定时检查。
// 配置（更新地址、每天一次、默认开启、不上报系统信息）全部在
// Resources/Info.plist 里，见 docs/release.md。
//
// Info.plist 的 SUPublicEDKey 已填入 cc-pilot 的真实公钥，所以包括本地开发构建在内都会启动 Sparkle，
// 并按计划访问 appcast 地址（见 docs/release.md "网络访问"）。下面对占位值的判断只是防护：公钥被换回
// 占位值（例如 fork 后还没生成自己的密钥）时不启动 Sparkle，既不联网，也不会因为公钥无效弹出
// "更新程序无法启动"的提示；"检查更新…"保持禁用。

import Combine
import Foundation
import Sparkle

@MainActor
final class Updater: NSObject, ObservableObject {
    /// 与 Resources/Info.plist、scripts/release.sh 中的占位值一致（32 个零字节的 base64）
    static let placeholderPublicKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    /// 定时检查发现了新版本。菜单栏 App 通常不在前台，Sparkle 不会抢焦点弹窗，由面板里的入口提示用户
    @Published private(set) var hasPendingUpdate = false

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        let configured = publicKey.map { !$0.isEmpty && $0 != Self.placeholderPublicKey } ?? false
        controller = SPUStandardUpdaterController(
            startingUpdater: configured, updaterDelegate: nil, userDriverDelegate: self)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
    }

    /// 已有更新窗口时（例如定时检查发现的）会把它带到前台
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}

// Sparkle 在主线程回调这些方法，但协议本身未标注 @MainActor
extension Updater: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated {
            if !userInitiated {
                hasPendingUpdate = true
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { hasPendingUpdate = false }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { hasPendingUpdate = false }
    }
}
