// 增量读取只追加写入的文件（会话记录、history.jsonl）：从上次读到的位置读新追加的完整行，
// 到最后一个换行为止，写到一半的最后一行留到下次。文件换了 inode 或变短（被重写）时从头读。

import Foundation

/// 一份文件读到的位置
struct FilePosition: Equatable {
    /// 已读完的字节数
    let offset: Int
    let inode: Int
}

struct AppendedLines {
    /// 这次从哪个偏移读起：没读过或文件被重写时是 0
    let start: Int
    /// 新追加的完整行（不含换行）
    let lines: [Data]
    /// 读完之后的位置；没有新的完整行时偏移就是 start
    let position: FilePosition

    /// 文件不存在或打不开时为 nil；seek、读取出错时抛错
    init?(path: String, after previous: FilePosition?) throws {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let size = Int(info.st_size), inode = Int(info.st_ino)
        var start = previous?.offset ?? 0
        if previous?.inode != inode || size < start { start = 0 }
        self.start = start
        guard size > start else {
            (lines, position) = ([], FilePosition(offset: start, inode: inode))
            return
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        guard let data = try handle.readToEnd(), let lastNewline = data.lastIndex(of: 0x0A) else {
            (lines, position) = ([], FilePosition(offset: start, inode: inode))
            return
        }
        let complete = data[data.startIndex...lastNewline]
        lines = complete.split(separator: 0x0A)
        position = FilePosition(offset: start + complete.count, inode: inode)
    }
}
