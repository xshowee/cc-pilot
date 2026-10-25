// ProfileWatcher 和 TokenUsageRecorder 共用的 FSEvents 小工具。

import CoreServices
import Foundation

enum FSEventsSupport {
    /// 事件丢失或需要重新扫描（说不清具体哪里变了）的标志
    static let rescanFlags = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)

    static func destroy(_ s: FSEventStreamRef) {
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    /// FSEvents 按解析过软链接的真实路径上报（例如 /var → /private/var）；解析不了时原样返回
    static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }
}
