// 进行中会话的归属（chatgpt-profiles ticket 08；spec "会话 → 档案归属顺序" 第 ① 步，09 复用）：
// 会话由哪个 codex 进程写入（它打开着 thread-writer-locks/<会话 ID>.lock 或会话记录本身），
// 那个进程环境里的 CODEX_HOME 就是会话所在的档案：
//   没有 CODEX_HOME（或为空）、或等于 ~/.codex     → 默认档案
//   ~/.codex-profiles/<名字>（合规的档案名）        → 该档案
//   其他路径                                       → 外部目录（不是 cc-pilot 的档案，不归属到任何账号）
// 读不出环境的进程不下结论（不能把它当默认档案）。
//
// 省电做法（ticket 08）：
//   - 每次调用只列一次进程（便宜）；每个进程只读一次环境（进程的环境不会变），进程退出后忘掉。
//   - 查打开的文件（贵）只在两种情况下做，一次查全部 codex 进程：进程集合与上次查时不同；或问到了
//     还没找到写入者、且在当前进程集合下还没问过的会话（新会话）。已知的会话再有变化不查。
//   - 找到过写入者的会话记住结果：进程退出后，它写过的事件仍属于它的档案；重查时发现会话被别的进程打开
//     （共享会话在另一个档案里被 resume），改归新进程的档案。
// 只在一个线程 / 串行队列上使用。

import Foundation

/// 会话的写入者
enum ChatGPTSessionWriter: Equatable {
    /// cc-pilot 的一个 ChatGPT 档案（默认档案是 "default"）
    case profile(String)
    /// CODEX_HOME 指向 cc-pilot 管理范围以外的目录
    case external(String)
    /// 没有找到正在写它的进程（09 接着按 history.jsonl 归属）
    case notFound
}

final class ChatGPTSessionWriters {
    private let query: CodexProcessQuery
    private let paths: ChatGPTProfilePaths

    /// 各进程环境里的 CODEX_HOME（读不出时记 nil，也不再读）
    private var homes: [CodexProcess: CodexHomeSetting?] = [:]
    /// 上次查打开的文件时的进程集合
    private var scannedProcesses: Set<CodexProcess>?
    /// 上次查打开的文件之后问过、但没找到写入者的会话
    private var unresolvedAsked: Set<String> = []
    /// 找到过的写入者
    private var known: [String: ChatGPTSessionWriter] = [:]

    init(environment: CoreEnvironment) {
        query = environment.codexProcesses
        paths = ChatGPTProfilePaths(environment: environment)
    }

    /// 这些会话各自的写入者
    func writers(of sessions: Set<String>) -> [String: ChatGPTSessionWriter] {
        let processes = query.codexProcesses()
        let running = Set(processes)
        for process in homes.keys where !running.contains(process) { homes[process] = nil }

        let unknown = sessions.filter { known[$0] == nil }
        if running != scannedProcesses || unknown.contains(where: { !unresolvedAsked.contains($0) }) {
            scan(processes)
            scannedProcesses = running
            unresolvedAsked = []
        }
        for session in sessions where known[session] == nil { unresolvedAsked.insert(session) }
        return Dictionary(uniqueKeysWithValues: sessions.map { ($0, known[$0] ?? .notFound) })
    }

    /// 查全部进程打开的文件，更新会话的写入者
    private func scan(_ processes: [CodexProcess]) {
        for process in processes {
            let sessions = Set(query.openFiles(of: process).compactMap(Self.sessionID(inOpenFile:)))
            guard !sessions.isEmpty, let writer = writer(for: home(of: process)) else { continue }
            for session in sessions { known[session] = writer }
        }
    }

    private func home(of process: CodexProcess) -> CodexHomeSetting? {
        if let cached = homes[process] { return cached }
        let home = query.codexHome(of: process)
        homes[process] = .some(home)
        return home
    }

    /// CODEX_HOME → 写入者；读不出环境时为 nil（不下结论）
    private func writer(for home: CodexHomeSetting?) -> ChatGPTSessionWriter? {
        guard let home else { return nil }
        guard case .path(let raw) = home else { return .profile(ProfileName.defaultName) }
        var path = raw
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let real = Self.realPath(path)
        if path == paths.defaultDirectoryPath || real == Self.realPath(paths.defaultDirectoryPath) {
            return .profile(ProfileName.defaultName)
        }
        for (candidate, root) in [(path, paths.profilesRootPath), (real, Self.realPath(paths.profilesRootPath))] {
            let parent = (candidate as NSString).deletingLastPathComponent
            let name = (candidate as NSString).lastPathComponent
            if parent == root, ProfileName.isProfileName(name) { return .profile(name) }
        }
        return .external(raw)
    }

    /// 打开的文件是写入锁 thread-writer-locks/<ID>.lock 或会话记录 rollout-…-<ID>.jsonl 时，其中的会话 ID
    static func sessionID(inOpenFile path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let directory = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        if directory == "thread-writer-locks", name.hasSuffix(".lock") {
            let id = String(name.dropLast(".lock".count))
            return id.isEmpty ? nil : id
        }
        if name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") {
            return CodexSessionLogParser.sessionID(fromFileName: name)
        }
        return nil
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
