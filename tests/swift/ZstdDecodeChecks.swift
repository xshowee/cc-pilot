// ticket 08（前置子任务）：纯 Swift 的 zstd 解码器，用来读取 Codex 压缩归档的会话记录 `rollout-*.jsonl.zst`。
// 接口：`Zstd.decompress(_:maximumOutput:)`，只解压。
// 期望值来源：tests/fixtures/zstd/ 下的 .zst 由 zstd 1.5.7 命令行从合成文本压出（见同目录 make-fixtures.zsh），
// expected.tsv 记着原文的字节数与 SHA-256（由 shasum 算出）；损坏输入的期望按 RFC 8878 手算。

import CryptoKit
import Foundation

final class ZstdDecodeChecks: CheckSuite {
    override class var checks: [Check] {
        [
            Check("空内容的帧解出空数据", emptyFrame),
            Check("同一字节重复的内容（RLE 块）原样解出", sameByteRun),
            Check("不可压缩的随机字节（Raw 块）原样解出", incompressible),
            Check("文本按 -1、-3、-19、--ultra -22 压缩后都能解出原文", textAtLevels),
            Check("超过 128 KB 的内容（多个压缩块，跨块重用表与重复偏移）解出原文", multipleBlocks),
            Check("帧头不带内容大小、声明 128 MB 长窗口（--long、从标准输入压缩）也能解出", windowDescriptor),
            Check("不带校验和的帧照常解出", withoutChecksum),
            Check("多个帧依次拼接，跳过帧被跳过", multipleFrames),
            Check("高度重复的内容（FSE 的 RLE / 重复模式、Treeless 字面量、单流 Huffman）解出原文", repetitiveLines),
            Check("只有字面量没有序列的块、Huffman 权重直接表示、一个块里超过 0x7F00 个序列都能解出",
                  rareEncodings),
            Check("手工拼的帧：Raw 字面量 + RLE 序列表，重叠复制按 RFC 手算得到 a 加 13 个 b", handBuiltSequence),
            Check("输出上限刚好够时成功，不够时报超限（不管帧头有没有声明大小）", outputLimit),
            Check("空输入、截断在任意位置都报错", truncatedInput),
            Check("内容校验和不符时报错", checksumMismatch),
            Check("需要字典的帧报明确的不支持字典", dictionaryRequired),
            Check("未知魔数、保留位、过大的窗口、内容大小不符都报错", malformedHeaders),
            Check("偏移超出已解出的内容、首个块就要重用之前的表都报错", invalidReferences),
            Check("逐字节破坏的输入不崩溃：要么报错，要么（只碰到无关位时）解出原文", corruptedBytesNeverCrash),
        ]
    }

    // MARK: 夹具

    static var fixtureDir: URL { repoRoot.appendingPathComponent("tests/fixtures/zstd") }

    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDir.appendingPathComponent(name))
    }

    /// expected.tsv：夹具名 → (原文字节数, 原文 SHA-256 十六进制)
    static func expected() throws -> [String: (size: Int, sha256: String)] {
        let text = try String(contentsOf: fixtureDir.appendingPathComponent("expected.tsv"), encoding: .utf8)
        var result: [String: (size: Int, sha256: String)] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            guard parts.count == 3, let size = Int(parts[1]) else { continue }
            result[parts[0]] = (size, parts[2])
        }
        return result
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 解压夹具并和 expected.tsv 对照
    static func expectDecodes(_ name: String) throws {
        let want = try unwrap(try expected()[name], "expected.tsv 里没有 \(name)")
        let output = try Zstd.decompress(try fixture(name))
        try expectEqual(output.count, want.size, "\(name) 解出的字节数")
        try expectEqual(sha256(output), want.sha256, "\(name) 解出内容的 SHA-256")
    }

    // MARK: 正常输入

    static func emptyFrame() throws {
        try expectDecodes("empty.zst")
    }

    static func sameByteRun() throws {
        try expectDecodes("same-byte.zst")
    }

    static func incompressible() throws {
        try expectDecodes("random.zst")
    }

    static func textAtLevels() throws {
        for name in ["small-1.zst", "small-3.zst", "small-19.zst", "small-22-ultra.zst"] {
            try expectDecodes(name)
        }
    }

    static func multipleBlocks() throws {
        for name in ["large-1.zst", "large-19.zst"] { try expectDecodes(name) }
    }

    static func windowDescriptor() throws {
        for name in ["small-3-long-stdin.zst"] { try expectDecodes(name) }
    }

    static func withoutChecksum() throws {
        for name in ["small-3-nocheck.zst", "small-19-stdin-nocheck.zst"] { try expectDecodes(name) }
    }

    static func multipleFrames() throws {
        for name in ["multi-frame.zst", "multi-frame-skippable.zst"] { try expectDecodes(name) }
    }

    static func repetitiveLines() throws {
        try expectDecodes("lines-19.zst")
    }

    static func rareEncodings() throws {
        for name in ["letters-1.zst", "nibbles-3.zst", "many-sequences-19.zst"] { try expectDecodes(name) }
    }

    // MARK: 手工拼的帧

    static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    /// 单段帧（帧头描述符 0x20：单段、1 字节内容大小、无校验和、无字典）+ 一个最后的压缩块
    static func singleSegmentFrame(contentSize: UInt8, block: [UInt8]) -> Data {
        let header = (block.count << 3) | (2 << 1) | 1
        return Data(magic + [0x20, contentSize]
            + [UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF), UInt8(header >> 16)] + block)
    }

    /// 压缩块内容（9 字节）：Raw 字面量 "ab"；1 个序列，三张表都是 RLE（LL 码 2、OF 码 `offsetCode`、
    /// ML 码 9）；比特流只有偏移码的额外位（全 0）和起始标记。压缩块必须比它解出的内容短，所以匹配要够长。
    static func oneSequenceBlock(offsetCode: UInt8) -> [UInt8] {
        let literals: [UInt8] = [2 << 3, 0x61, 0x62]  // Raw、1 字节头、大小 2
        let sequences: [UInt8] = [0x01, 0x54, 0x02, offsetCode, 0x09]  // 序列数 1；模式 01 01 01 00
        return literals + sequences + [UInt8(1) << offsetCode]
    }

    static func handBuiltSequence() throws {
        // LL 码 2 → 2 个字面量 "ab"；OF 码 2、额外位 0 → 偏移值 4 → 偏移 1；ML 码 9 → 匹配长度 12。
        // 从 1 字节之前复制 12 字节（与正在写的部分重叠）："ab" + 12 个 "b"
        let frame = singleSegmentFrame(contentSize: 14, block: oneSequenceBlock(offsetCode: 2))
        try expectEqual(String(decoding: try Zstd.decompress(frame), as: UTF8.self), "abbbbbbbbbbbbb")
    }

    // MARK: 损坏与超限

    /// 解压应当失败；`matching` 不为 nil 时还要求错误符合它
    static func expectFailure(_ data: Data, maximumOutput: Int = Zstd.defaultMaximumOutput,
                              _ what: String, matching: ((ZstdError) -> Bool)? = nil) throws {
        do {
            let output = try Zstd.decompress(data, maximumOutput: maximumOutput)
            throw CheckFailure(description: "\(what)：应当报错，却解出了 \(output.count) 字节")
        } catch let error as ZstdError {
            if let matching { try expect(matching(error), "\(what)：错误不对，得到 \(error)") }
        }
    }

    static func outputLimit() throws {
        // same-byte.zst 的帧头声明 300000 字节；small-3-long-stdin.zst 不声明大小（41261 字节）
        let declared = try fixture("same-byte.zst")
        try expectEqual(try Zstd.decompress(declared, maximumOutput: 300_000).count, 300_000)
        try expectFailure(declared, maximumOutput: 299_999, "声明大小超过上限") {
            $0 == .outputTooLarge(limit: 299_999)
        }
        let undeclared = try fixture("small-3-long-stdin.zst")
        try expectEqual(try Zstd.decompress(undeclared, maximumOutput: 41261).count, 41261)
        try expectFailure(undeclared, maximumOutput: 41260, "解到一半超过上限") {
            $0 == .outputTooLarge(limit: 41260)
        }
    }

    static func truncatedInput() throws {
        try expectFailure(Data(), "空输入") { $0 == .truncated }
        // 小夹具逐个前缀截断；大一些的按步长截断
        let small = try fixture("nibbles-3.zst")
        for length in 1..<small.count {
            try expectFailure(small.prefix(length), "nibbles-3.zst 截断到 \(length) 字节")
        }
        let text = try fixture("small-3-nocheck.zst")
        for length in stride(from: 1, to: text.count, by: 211) {
            try expectFailure(text.prefix(length), "small-3-nocheck.zst 截断到 \(length) 字节")
        }
        try expectFailure(text.dropLast(), "small-3-nocheck.zst 少最后一个字节")
    }

    static func checksumMismatch() throws {
        var data = try fixture("small-3.zst")
        data[data.count - 1] ^= 0x01
        try expectFailure(data, "改了校验和") { $0 == .checksumMismatch }
    }

    static func dictionaryRequired() throws {
        // 描述符 0x21：单段、字典 ID 占 1 字节；字典 ID 7；内容大小 0；一个空的 Raw 块
        let frame = Data(magic + [0x21, 0x07, 0x00, 0x01, 0x00, 0x00])
        try expectFailure(frame, "带字典 ID") { $0 == .dictionaryNotSupported(dictionaryID: 7) }
    }

    static func malformedHeaders() throws {
        let emptyRawBlock: [UInt8] = [0x01, 0x00, 0x00]
        try expectFailure(Data([0x28, 0xB5, 0x2F, 0xFE, 0x20, 0x00] + emptyRawBlock), "未知魔数") {
            $0 == .unknownMagic(0xFE2F_B528)
        }
        // 合法帧后面跟着不认识的字节
        try expectFailure(try fixture("empty.zst") + Data([0x00, 0x01, 0x02, 0x03]), "帧后有垃圾") {
            $0 == .unknownMagic(0x0302_0100)
        }
        try expectFailure(Data(magic + [0x28, 0x00] + emptyRawBlock), "保留位为 1") { $0 == .reservedBitSet }
        // 非单段帧，窗口描述符 0xF8：指数 31 → 2^41 字节的窗口
        try expectFailure(Data(magic + [0x00, 0xF8] + emptyRawBlock), "窗口过大") { $0 == .windowTooLarge }
        // 声明 5 字节，Raw 块只给 3 字节
        try expectFailure(Data(magic + [0x20, 0x05, 0x19, 0x00, 0x00, 0x61, 0x62, 0x63]), "内容大小不符") {
            $0 == .contentSizeMismatch(declared: 5, actual: 3)
        }
        // 保留的块类型 3
        try expectFailure(Data(magic + [0x20, 0x00, 0x07, 0x00, 0x00]), "保留的块类型")
    }

    static func invalidReferences() throws {
        // 同 handBuiltSequence，但 OF 码 5 → 偏移值 32 → 偏移 29，而此时只解出了 2 字节
        try expectFailure(singleSegmentFrame(contentSize: 14, block: oneSequenceBlock(offsetCode: 5)),
                          "偏移超出已解出的内容") { if case .corrupt = $0 { return true } else { return false } }
        // 帧里的第一个块就用 Treeless 字面量（重用上一张 Huffman 表）
        try expectFailure(singleSegmentFrame(contentSize: 100, block: [0x03, 0x00, 0x00, 0x00]), "没有可重用的 Huffman 表")
        // 帧里的第一个块就用序列表重复模式
        try expectFailure(singleSegmentFrame(contentSize: 100, block: [0x00, 0x01, 0xFC, 0x01]), "没有可重用的序列表")
    }

    static func corruptedBytesNeverCrash() throws {
        // 夹具都带校验和：被改坏的输入要么报错，要么改到的是解码不关心的位、仍解出原文。
        // 崩溃（越界、溢出）或死循环会让整个检查程序失败 / 卡住。
        for name in ["nibbles-3.zst", "small-19.zst"] {
            let original = try fixture(name)
            let want = try unwrap(try expected()[name])
            let step = original.count < 2000 ? 1 : 13
            for index in stride(from: 0, to: original.count, by: step) {
                for flip: UInt8 in [0xFF, 0x10] {
                    var data = original
                    data[index] ^= flip
                    if let output = try? Zstd.decompress(data) {
                        try expect(output.count == want.size && sha256(output) == want.sha256,
                                   "\(name) 第 \(index) 字节异或 \(flip) 后没报错，却解出了不同的内容")
                    }
                }
            }
        }
    }
}
