// App 核心与外部世界的接触点。核心里所有读文件、调外部程序、联网的地方都从这里取依赖，
// 测试通过构造参数替换成临时目录或替身（spec "Testing Decisions"：只替换 HOME、外部程序、网络层）。
//
// 扩展方式：新增一个带默认值的存储属性，并在 init 里加一个带默认值的参数，
// 已有调用点（`CoreEnvironment()`、`CoreEnvironment(home:)`）不用改。
// 预计的扩展：外部程序路径（ticket 10，如 security）、当前用户名（ticket 10）、网络层（ticket 11）、当前时间。
//
// 本目录（Sources/Core）只依赖 Foundation / CoreServices 等系统框架，不 import SwiftUI / AppKit。

import Foundation

struct CoreEnvironment {
    /// 用户主目录。默认档案的 .claude.json、~/.claude-profiles/ 都相对于它。
    var home: URL

    init(home: URL = CoreEnvironment.userHome()) {
        self.home = home
    }

    /// 真实环境
    static var live: CoreEnvironment { CoreEnvironment() }

    /// 用户主目录：优先用环境变量 HOME（Claude Code 的 os.homedir() 和 ccp 都以它为准），
    /// 没有时才用系统记录的主目录。从 Finder / launchd 启动时两者相同。
    static func userHome() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
