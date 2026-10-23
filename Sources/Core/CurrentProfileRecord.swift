// 当前档案记录 ~/.claude-profiles/active 的读取与切换（见 GLOSSARY.md "当前档案"、"切换"）。
//
// 与 shell 完全一致（spec "磁盘上的文件约定"）：
// - 读取同 shell/lib/profiles.zsh 的 _ccp_active_name：只取第一行，去掉首尾空白（含 \r）；
//   记录不存在、读不了或为空时是 default。不校验名字。
// - 切换同 `ccp use`（shell/lib/cmd-use.zsh）：内容是档案名加一个换行，UTF-8 无 BOM；
//   切回默认档案时写入 "default\n"，不删除记录。原子写入：在同一目录下建临时文件
//   .active.XXXXXX（mkstemp，权限 0600，与 mktemp 相同），写完后 rename 到 active。
//   名字不合规、是保留名、档案目录不存在、或记录的位置是目录时拒绝，记录保持不变。
//
// 切换只写这一个文件：不读凭据、不联网，也不影响已在运行的会话。

import Foundation

struct CurrentProfileRecord {
    private let paths: ProfilePaths

    init(environment: CoreEnvironment = .live) {
        paths = ProfilePaths(environment: environment)
    }

    /// 当前档案的名字（"default" 表示默认档案）。可能是一个不合规或不存在的名字，原样返回。
    func currentName() -> String {
        guard let data = try? Data(contentsOf: paths.activeRecord) else { return ProfileName.defaultName }
        let firstLine = data.prefix { $0 != UInt8(ascii: "\n") }
        // 与 zsh 的 [[:space:]] 一致，只去掉 ASCII 空白（空格、\t、\v、\f、\r）
        let name = String(decoding: firstLine, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t\u{0B}\u{0C}\r"))
        return name.isEmpty ? ProfileName.defaultName : name
    }

    /// 把当前档案切换为 name（"default" 表示默认档案）。
    /// 失败时抛出 SwitchError，记录保持不变。
    func switchTo(_ name: String) throws {
        let fm = FileManager.default
        if name != ProfileName.defaultName {
            guard ProfileName.isProfileName(name) else { throw SwitchError.invalidName }
            guard Self.isDirectory(paths.configDir(for: name)) else { throw SwitchError.profileMissing }
        }
        let record = paths.activeRecord.path
        // rename 到一个目录上会失败或把文件放进去（软链接指向目录时），ccp use 同样拒绝
        guard !Self.isDirectory(record) else { throw SwitchError.recordIsDirectory }

        let root = paths.profilesRootPath
        do {
            try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
            let code = underlying?.domain == NSPOSIXErrorDomain ? Int32(underlying!.code) : EIO
            throw SwitchError.writeFailed(errno: code)
        }
        try atomicWrite(Data((name + "\n").utf8), to: record, tempDir: root)
    }

    /// 是否为目录（跟随软链接，与 shell 的 [[ -d ]] 一致）
    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 在 tempDir 里用 mkstemp 建临时文件，写完、落盘后 rename 到 target；失败时删掉临时文件。
    private func atomicWrite(_ data: Data, to target: String, tempDir: String) throws {
        var template = Array((tempDir + "/.active.XXXXXX").utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw SwitchError.writeFailed(errno: errno) }
        let tempPath = String(cString: template)
        var ok = false
        defer { if !ok { unlink(tempPath) } }

        let written = data.withUnsafeBytes { buf -> Int in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                offset += n
            }
            return offset
        }
        let writeErrno = errno
        guard written == data.count else { close(fd); throw SwitchError.writeFailed(errno: writeErrno) }
        let synced = fsync(fd) == 0 ? 0 : errno
        let closed = close(fd) == 0 ? 0 : errno
        guard synced == 0, closed == 0 else { throw SwitchError.writeFailed(errno: synced != 0 ? synced : closed) }
        guard rename(tempPath, target) == 0 else { throw SwitchError.writeFailed(errno: errno) }
        ok = true
    }

    enum SwitchError: Error, Equatable {
        /// 名字不符合档案名规则，或是保留名 active
        case invalidName
        /// ~/.claude-profiles/<名字>/ 不存在或不是目录
        case profileMissing
        /// ~/.claude-profiles/active 的位置是一个目录
        case recordIsDirectory
        /// 创建档案根目录、临时文件、写入或重命名失败（errno 为系统错误码）
        case writeFailed(errno: Int32)
    }
}
