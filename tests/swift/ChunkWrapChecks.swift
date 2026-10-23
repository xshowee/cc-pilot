// ticket 23：额度窗口行（标题、剩余、重置时间）宽度不足时整段折到下一行，不截断任何一段。
// 期望值按宽度手算：放得下就跟在同一行（中间隔 spacing），放不下就整段换行。

import Foundation

final class ChunkWrapChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("放得下时所有片段在同一行，依次隔开", fitsOnOneLine),
            Check("放不下的片段整段折到下一行，从行首开始", overflowMovesWholeChunk),
            Check("刚好放满不折行", exactFitStaysOnLine),
            Check("比整行还宽的片段单独占一行，不会在它前面留一个空行", wideChunkGetsOwnLine),
            Check("不限宽度时全部在一行", unlimitedWidthIsOneLine),
            Check("折行后的行继续按宽度排", wrapsRepeatedly),
        ]
    }

    static func place(_ widths: [Double], _ maxWidth: Double?) -> [ChunkWrap.Placement] {
        ChunkWrap.place(widths: widths, maxWidth: maxWidth, spacing: 4)
    }

    static func fitsOnOneLine() throws {
        try expectEqual(place([60, 40, 70], 200), [
            .init(line: 0, x: 0), .init(line: 0, x: 64), .init(line: 0, x: 108),
        ])
    }

    static func overflowMovesWholeChunk() throws {
        // "周窗口（全部模型）" 100 + "剩余 2%" 40 + "· 10/24 14:59 重置" 90，宽 200：
        // 100 + 4 + 40 = 144，再加 4 + 90 = 238 > 200，重置时间整段换行
        try expectEqual(place([100, 40, 90], 200), [
            .init(line: 0, x: 0), .init(line: 0, x: 104), .init(line: 1, x: 0),
        ])
    }

    static func exactFitStaysOnLine() throws {
        try expectEqual(place([100, 40, 52], 200), [
            .init(line: 0, x: 0), .init(line: 0, x: 104), .init(line: 0, x: 148),
        ])
    }

    static func wideChunkGetsOwnLine() throws {
        try expectEqual(place([250, 40], 200), [.init(line: 0, x: 0), .init(line: 1, x: 0)])
        try expectEqual(place([40, 250, 40], 200), [
            .init(line: 0, x: 0), .init(line: 1, x: 0), .init(line: 2, x: 0),
        ])
    }

    static func unlimitedWidthIsOneLine() throws {
        try expectEqual(place([100, 40, 90], nil), [
            .init(line: 0, x: 0), .init(line: 0, x: 104), .init(line: 0, x: 148),
        ])
    }

    static func wrapsRepeatedly() throws {
        try expectEqual(place([80, 80, 80, 30], 170), [
            .init(line: 0, x: 0), .init(line: 0, x: 84), .init(line: 1, x: 0), .init(line: 1, x: 84),
        ])
    }
}
