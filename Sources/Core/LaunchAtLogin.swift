// "登录时启动"。状态总是以系统登录项为准（用户也可能在"系统设置 › 登录项"里改）；
// 默认关闭：除了用户打开开关，没有任何地方会注册登录项。
// App 里由 SMAppService.mainApp 实现 LoginItemService（见 Sources/App/LaunchAtLoginModel.swift）。

import Foundation

/// 系统登录项
protocol LoginItemService {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

final class LaunchAtLogin {
    private let service: LoginItemService

    init(service: LoginItemService) {
        self.service = service
    }

    var isEnabled: Bool { service.isEnabled }

    /// 打开或关闭。已与系统一致时什么也不做；失败时抛出系统给的错误，状态仍以系统为准。
    func setEnabled(_ enabled: Bool) throws {
        guard enabled != service.isEnabled else { return }
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
