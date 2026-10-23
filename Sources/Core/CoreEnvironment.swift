// App 核心与外部世界的接触点。核心里所有读文件、调外部程序、联网的地方都从这里取依赖，
// 测试通过构造参数替换成临时目录或替身（spec "Testing Decisions"：只替换 HOME、外部程序、网络层）。
//
// 扩展方式：新增一个带默认值的存储属性，并在 init 里加一个带默认值的参数，
// 已有调用点（`CoreEnvironment()`、`CoreEnvironment(home:)`）不用改。
// 当前时间不放在这里，由各方法的 `now` 参数传入。
//
// 本目录（Sources/Core）只依赖 Foundation / CoreServices 等系统框架，不 import SwiftUI / AppKit。

import Foundation

struct CoreEnvironment {
    /// 用户主目录。默认档案的 .claude.json、~/.claude-profiles/ 都相对于它。
    var home: URL
    /// 系统的 security 程序（读取凭据用）。测试换成假程序，绝不能让检查程序调用真的。
    var security: URL
    /// 当前用户名：钥匙串项匹配到多条时，优先取 account 等于它的那条（Claude Code 写入时用 $USER）
    var userName: String
    /// 运行 ccp 等 shell 脚本时给它的 PATH。默认只有系统目录（与从 Finder 启动的 App 相同）；
    /// 测试在最前面放假的 claude / security。
    var searchPath: String
    /// 单次调用 security 的最长等待时间（秒）。超时视为出现了授权弹窗，按"版本不兼容"处理。
    var securityTimeout: TimeInterval
    /// 网络层：App 核心只通过它访问额度接口。测试换成假的，绝不能让检查程序访问真的网络。
    var transport: UsageTransport
    /// App 版本号，额度请求的 User-Agent 写成 cc-pilot/<版本>
    var appVersion: String

    init(home: URL = CoreEnvironment.userHome(),
         security: URL = URL(fileURLWithPath: "/usr/bin/security"),
         userName: String = NSUserName(),
         securityTimeout: TimeInterval = 5,
         searchPath: String = "/usr/bin:/bin:/usr/sbin:/sbin",
         transport: UsageTransport = URLSessionUsageTransport.shared,
         appVersion: String = CoreEnvironment.bundleVersion()) {
        self.home = home
        self.security = security
        self.userName = userName
        self.securityTimeout = securityTimeout
        self.searchPath = searchPath
        self.transport = transport
        self.appVersion = appVersion
    }

    /// 真实环境
    static var live: CoreEnvironment { CoreEnvironment() }

    /// Info.plist 里的版本号（CFBundleShortVersionString）；没有时（例如检查程序）为 "dev"
    static func bundleVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    /// 用户主目录：优先用环境变量 HOME（Claude Code 的 os.homedir() 和 ccp 都以它为准），
    /// 没有时才用系统记录的主目录。从 Finder / launchd 启动时两者相同。
    static func userHome() -> URL {
        if let home = ProcessInfo.processInfo.environment["HOME"], home.hasPrefix("/") {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
