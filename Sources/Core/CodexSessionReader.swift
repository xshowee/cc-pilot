// ChatGPT 会话记录的唯一读取器（chatgpt-profiles ticket 08；09 的 Token 账本复用，实时额度也用它）。
//
// 会话目录是共享的（ADR 0006：各档案的 sessions/、archived_sessions/ 是指向 ~/.codex 下同名目录的软链接），
// 所以只读 ~/.codex/sessions/ 与 ~/.codex/archived_sessions/ 各一次，不按档案重复扫描，也不跟随目录里的软链接。
// 文件：rollout-*.jsonl 与压缩归档的 rollout-*.jsonl.zst（以 . 开头的跳过）。
//
// 增量读取：scan 接收上次的读取位置（CodexFileCursor，按路径），返回新的位置与这次新读到的内容。
//   .jsonl     从上次的偏移读新追加的完整行（AppendedLines：写到一半的最后一行留到下次；文件被重写时从头读、
//              上下文也重来）。
//   .jsonl.zst 不能按偏移增量读：大小、inode、修改时间都没变就跳过，变了就整份解压重读（重读出的事件靠去重键
//              不重复计入）。截断（正在写入）或读文件出错时位置不动，记进 deferred，下次再试；
//              其他解压错误（损坏、要字典、超过上限）记下位置跳过，文件再变才重读。
// 只扫描 under 给出的目录时，别处文件的位置原样保留；扫描过的目录里已不存在的文件，位置被忘掉。
// under 里的目录可以互相包含（FSEvents 一批里同时报告父目录与子目录，例如零点新建日期目录时）：
// 每份文件只读一次——否则每个包含它的目录都从同一个旧位置读一遍，同一批新事件会重复报告。
// 只读文件，不写任何东西；读不了的文件跳过。调用方负责在一个线程 / 串行队列上使用。

import Foundation

/// 一次扫描的结果
struct CodexSessionScan {
    /// 读完之后全部文件的位置（下次传回 scan）
    var cursors: [String: CodexFileCursor]
    /// 这次读到首行的各会话记录自己的 session_meta（按文件路径顺序）
    var sessions: [CodexSessionMeta] = []
    /// 这次新读到的 token_count 事件（文件按路径排序，文件内按顺序）
    var events: [CodexTokenCountEvent] = []
    /// 这次读不了、位置没动、下次再试的文件
    var deferred: [String] = []
}

struct CodexSessionReader {
    private let paths: ChatGPTProfilePaths

    init(environment: CoreEnvironment) {
        paths = ChatGPTProfilePaths(environment: environment)
    }

    /// 两个会话目录：~/.codex/sessions、~/.codex/archived_sessions
    var roots: [String] {
        [paths.defaultDirectoryPath + "/sessions", paths.defaultDirectoryPath + "/archived_sessions"]
    }

    /// 扫描会话目录。under 为 nil 时扫描两个会话目录的全部；否则只扫描这些目录（及其子目录）
    func scan(_ cursors: [String: CodexFileCursor], under directories: [String]? = nil) -> CodexSessionScan {
        let given = Set((directories ?? roots).map(Self.trimmingSlash))
        // 被别的目录包含的不再单独枚举；文件列表再去重一次，保证每份文件只读一次
        let scopes = given.filter { scope in !given.contains(where: { Self.isInside(scope, $0) }) }.sorted()
        var result = CodexSessionScan(cursors: cursors)
        let files = Set(scopes.flatMap(Self.rolloutFiles)).sorted()
        let found = Set(files)
        for path in cursors.keys where !found.contains(path) && scopes.contains(where: { Self.isInside(path, $0) }) {
            result.cursors[path] = nil
        }
        for path in files {
            do {
                guard let read = try Self.read(path, after: cursors[path]) else {
                    result.cursors[path] = nil
                    continue
                }
                result.cursors[path] = read.cursor
                if let meta = read.meta { result.sessions.append(meta) }
                result.events += read.events
            } catch {
                result.deferred.append(path)
            }
        }
        return result
    }

    /// 读一份会话记录在 previous 之后的新内容；文件不存在时为 nil；暂时读不了（.zst 正在写入等）时抛错
    static func read(_ path: String, after previous: CodexFileCursor?) throws
        -> (cursor: CodexFileCursor, meta: CodexSessionMeta?, events: [CodexTokenCountEvent])? {
        let name = (path as NSString).lastPathComponent
        if name.hasSuffix(".zst") {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            let size = Int(info.st_size), inode = Int(info.st_ino)
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            if let previous, previous.offset == size, previous.inode == inode, previous.modified == modified {
                return (previous, nil, [])
            }
            let cursor = CodexFileCursor(offset: size, inode: inode, modified: modified)
            let content: Data
            do {
                content = try Zstd.decompress(try Data(contentsOf: URL(fileURLWithPath: path)))
            } catch let error as ZstdError where error != .truncated {
                // 损坏、要字典、超过上限：不是"稍后再试"，记下位置跳过，文件变了才再读
                NSLog("CC Pilot: 跳过无法解压的会话记录 %@：%@", path, String(describing: error))
                return (cursor, nil, [])
            }
            var parser = CodexSessionLogParser(cursor: cursor, fileName: name)
            for line in content.split(separator: 0x0A) { parser.parse(line) }
            return (parser.cursor, parser.meta, parser.events)
        }
        let position = previous.map { FilePosition(offset: $0.offset, inode: $0.inode) }
        guard let appended = try AppendedLines(path: path, after: position) else { return nil }
        // 从头读（第一次读、或文件被重写）时上下文重来
        var start = appended.start == 0 ? CodexFileCursor(offset: 0, inode: appended.position.inode) : previous!
        start.offset = appended.position.offset
        start.inode = appended.position.inode
        var parser = CodexSessionLogParser(cursor: start, fileName: name)
        for line in appended.lines { parser.parse(line) }
        return (parser.cursor, parser.meta, parser.events)
    }

    /// 目录下（递归，不跟随软链接）的会话记录文件；目录本身是软链接时照常进入
    private static func rolloutFiles(under directory: String) -> [String] {
        // 枚举出的是相对路径：报告的路径以调用方给的目录为前缀（目录本身是软链接时也一样），位置按它记
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            if name.hasPrefix(".") {
                if enumerator.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst"),
                  enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
            files.append(directory + "/" + relative)
        }
        return files
    }

    private static func trimmingSlash(_ path: String) -> String {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    private static func isInside(_ path: String, _ directory: String) -> Bool {
        path.hasPrefix(directory + "/")
    }
}
