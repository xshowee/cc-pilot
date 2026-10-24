// 实时额度的文件约定（token-usage ticket 04，ADR 0004；与 shell/lib/profiles.zsh、cmd-statusline.zsh 一致）：
//
//   实时额度目录  $HOME/.claude-profiles/.live-quota/（以 . 开头：ProfileStore 和 ccp ls 都不会把它当成档案）
//     <档案名>.json   状态栏转发命令 ccp statusline 写出的最近一次状态栏数据，默认档案是 default.json。
//                     JSON（status 原样嵌入，不保证只有一行）：{"profile":"<档案名>","received_at":<Unix 秒，带小数>,"status":<Claude Code 给状态栏的原始 JSON>}
//                     写法是同目录临时文件 .<档案名>.json.<pid> + rename，读的时候忽略以 . 开头的文件。
//     disabled        存在即关闭状态栏转发：claude 包装函数每次启动时检查它，存在就不加 --settings 覆盖；
//                     不存在时默认开启。App 设置菜单里的开关写它。
//
// 文件变化由 ProfileWatcher 的 onLiveQuotaChange 通知（与档案变化分开，短时间内的多次写入合并）。

import Foundation

struct LiveQuotaFiles: Sendable {
    let environment: CoreEnvironment
    private var paths: ProfilePaths { ProfilePaths(environment: environment) }

    init(environment: CoreEnvironment = .live) {
        self.environment = environment
    }

    /// 实时额度目录名（在档案根目录下）
    static let directoryName = ".live-quota"

    /// 实时额度目录：$HOME/.claude-profiles/.live-quota
    var directory: URL {
        URL(fileURLWithPath: paths.profilesRootPath + "/" + Self.directoryName, isDirectory: true)
    }

    /// 某个档案的实时额度文件（默认档案传 "default"）
    func file(for profileName: String) -> URL {
        directory.appendingPathComponent(profileName + ".json")
    }

    /// 关闭状态栏转发的标记文件
    var disabledFlag: URL { directory.appendingPathComponent("disabled") }

    /// 状态栏转发是否开启（标记文件不存在即开启；是软链接、目录也算存在，与 shell 的 [[ -e ]] 一致）
    var isForwardingEnabled: Bool {
        (try? FileManager.default.attributesOfItem(atPath: disabledFlag.path)) == nil
    }

    /// 打开或关闭状态栏转发：关闭时建立标记文件（目录不存在时一并建立），打开时删除它。
    /// 已经是目标状态时什么都不做；只影响之后启动的会话。
    func setForwardingEnabled(_ enabled: Bool) throws {
        guard enabled != isForwardingEnabled else { return }
        let fm = FileManager.default
        if enabled {
            try fm.removeItem(at: disabledFlag)
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: disabledFlag)
        }
    }
}
