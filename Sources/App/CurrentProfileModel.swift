// 当前档案的界面状态：菜单栏第一行和面板里的高亮都读它；点击档案时调用 switchTo。
//
// 有自己的 ProfileWatcher：在终端里用 `ccp use` 切换时，当前档案记录变化，这里重读并发布，
// 菜单栏跟着更新。切换只写当前档案记录（App 核心 CurrentProfileRecord），不读凭据、不联网。

import AppKit
import Foundation

@MainActor
final class CurrentProfileModel: ObservableObject {
    /// 当前档案名（"default" 表示默认档案）；可能是一个已不存在的档案名，原样显示
    @Published private(set) var name: String

    private let record: CurrentProfileRecord
    private var watcher: ProfileWatcher?

    init(environment: CoreEnvironment = .live) {
        record = CurrentProfileRecord(environment: environment)
        name = record.currentName()
        let watcher = ProfileWatcher(environment: environment) { [weak self] in
            Task { @MainActor in self?.reload() }
        }
        watcher.start()
        self.watcher = watcher
    }

    /// 重读当前档案记录（只有一行，直接在主线程读）
    func reload() {
        let latest = record.currentName()
        if latest != name { name = latest }
    }

    /// 把 profile 设为当前档案，效果与 `ccp use <名字>` 相同。
    /// 失败（例如档案刚被 ccp rm 删掉）时记录保持不变，提示音并记日志。
    func switchTo(_ profile: String) {
        guard profile != name else { return }
        do {
            try record.switchTo(profile)
            name = profile
        } catch {
            NSLog("CC Pilot: 切换到档案 %@ 失败：%@", profile, String(describing: error))
            NSSound.beep()
            reload()
        }
    }
}
