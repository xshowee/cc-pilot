// 纯 Swift 的 zstd 解码器（只解压），按 RFC 8878 实现（ticket 08）。
// 用途：Codex 把归档的会话记录压成 `rollout-*.jsonl.zst`，而系统没有可用的 zstd 解码器
// （Compression.framework 不支持 zstd，不能依赖外部程序，也不打包 C 源码）。
//
// 支持：多帧与跳过帧、Raw / RLE / Compressed 块、Huffman 字面量（1 流与 4 流、重用上一张表）、
// FSE 序列（预定义 / RLE / 压缩 / 重复模式）、重复偏移、内容大小与 XXH64 内容校验和。
// 不支持字典（帧头带非零字典 ID 时抛 `.dictionaryNotSupported`）。
// 损坏输入一律抛 `ZstdError`，所有读取都有边界检查、所有循环都有上界；输出总量不超过 `maximumOutput`。

import Foundation

enum ZstdError: Error, Equatable {
    /// 输入为空或在帧 / 块中间结束
    case truncated
    /// 不是 zstd 帧（也不是跳过帧）的魔数
    case unknownMagic(UInt32)
    /// 帧头的保留位不为 0
    case reservedBitSet
    /// 帧要求字典，这里不支持
    case dictionaryNotSupported(dictionaryID: UInt32)
    /// 帧声明的窗口超过支持的上限
    case windowTooLarge
    /// 解压结果会超过调用方给的上限
    case outputTooLarge(limit: Int)
    /// 帧头声明的内容大小与实际解出的不一致
    case contentSizeMismatch(declared: UInt64, actual: Int)
    /// 内容校验和（XXH64 低 32 位）不一致
    case checksumMismatch
    /// 其他格式错误（块、字面量、序列、熵编码表）
    case corrupt(String)
}

enum Zstd {
    /// 默认输出上限：256 MiB。会话记录通常只有几 MB。
    static let defaultMaximumOutput = 256 << 20

    /// 解压一段 zstd 数据（可含多个帧与跳过帧），返回所有帧内容依次拼接的结果。
    /// 帧带内容校验和时一定校验。输入为空视为截断。
    static func decompress(_ data: Data, maximumOutput: Int = defaultMaximumOutput) throws -> Data {
        guard !data.isEmpty else { throw ZstdError.truncated }
        let output = Output(limit: max(0, maximumOutput))
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var input = Input(raw)
            while !input.isAtEnd {
                try decodeFrame(&input, into: output)
            }
        }
        return output.data()
    }

    // MARK: 帧

    static let frameMagic: UInt32 = 0xFD2F_B528
    /// 窗口上限 2^31（RFC 允许解码器拒绝更大的窗口；只用来校验，不按窗口分配内存）
    static let maximumWindowLog = 31
    static let maximumBlockSize = 128 << 10

    private static func decodeFrame(_ input: inout Input, into output: Output) throws {
        let magic = try input.readLE(4)
        if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
            // 跳过帧：4 字节长度 + 用户数据
            let size = try input.readLE(4)
            try input.skip(Int(size))
            return
        }
        guard magic == UInt64(frameMagic) else { throw ZstdError.unknownMagic(UInt32(magic)) }

        let descriptor = try input.readByte()
        let contentSizeFlag = Int(descriptor >> 6)
        let singleSegment = descriptor & 0x20 != 0
        let hasChecksum = descriptor & 0x04 != 0
        let dictionaryIDFlag = Int(descriptor & 0x03)
        if descriptor & 0x08 != 0 { throw ZstdError.reservedBitSet }

        var windowSize: UInt64 = 0
        if !singleSegment {
            let window = try input.readByte()
            let windowLog = 10 + Int(window >> 3)
            if windowLog > maximumWindowLog { throw ZstdError.windowTooLarge }
            let base = UInt64(1) << windowLog
            windowSize = base + (base / 8) * UInt64(window & 0x07)
        }
        let dictionaryID = try input.readLE([0, 1, 2, 4][dictionaryIDFlag])
        if dictionaryID != 0 { throw ZstdError.dictionaryNotSupported(dictionaryID: UInt32(dictionaryID)) }

        var contentSize: UInt64?
        switch contentSizeFlag {
        case 0: contentSize = singleSegment ? try input.readLE(1) : nil
        case 1: contentSize = try input.readLE(2) + 256
        case 2: contentSize = try input.readLE(4)
        default: contentSize = try input.readLE(8)
        }
        if singleSegment { windowSize = contentSize ?? 0 }
        if let contentSize {
            if contentSize > UInt64(output.limit - output.count) {
                throw ZstdError.outputTooLarge(limit: output.limit)
            }
            // 声明的大小只用来预留空间，单次最多预留 64 MiB，防止损坏的帧头一次要很大内存
            output.reserve(output.count + min(Int(contentSize), 64 << 20))
        }

        let frameStart = output.count
        let blockLimit = Int(min(windowSize, UInt64(maximumBlockSize)))
        var state = FrameState()
        var lastBlock = false
        while !lastBlock {
            let header = Int(try input.readLE(3))
            lastBlock = header & 1 != 0
            let blockType = (header >> 1) & 0x03
            let blockSize = header >> 3
            switch blockType {
            case 0: // Raw
                guard blockSize <= blockLimit else { throw ZstdError.corrupt("块大小 \(blockSize) 超过上限") }
                let bytes = try input.take(blockSize)
                try output.append(bytes)
            case 1: // RLE：块大小是重复次数，内容只有 1 字节
                guard blockSize <= blockLimit else { throw ZstdError.corrupt("块大小 \(blockSize) 超过上限") }
                let byte = try input.readByte()
                try output.appendRepeating(byte, count: blockSize)
            case 2: // Compressed
                guard blockSize <= blockLimit else { throw ZstdError.corrupt("块大小 \(blockSize) 超过上限") }
                let block = try input.take(blockSize)
                try decodeCompressedBlock(block, state: &state, output: output, frameStart: frameStart,
                                          blockLimit: blockLimit)
            default:
                throw ZstdError.corrupt("保留的块类型")
            }
        }

        let produced = output.count - frameStart
        if let contentSize, contentSize != UInt64(produced) {
            throw ZstdError.contentSizeMismatch(declared: contentSize, actual: produced)
        }
        if hasChecksum {
            let stored = UInt32(try input.readLE(4))
            let actual = output.withBytes(from: frameStart) { UInt32(truncatingIfNeeded: XXH64.hash($0)) }
            if stored != actual { throw ZstdError.checksumMismatch }
        }
    }

    // MARK: 压缩块

    private static func decodeCompressedBlock(_ block: UnsafeRawBufferPointer, state: inout FrameState,
                                              output: Output, frameStart: Int, blockLimit: Int) throws {
        var input = Input(block)
        let literals = try decodeLiterals(&input, state: &state, blockLimit: blockLimit)
        try literals.withUnsafeBytes { literals in
            try decodeSequences(&input, literals: literals, state: &state, output: output,
                                frameStart: frameStart, blockLimit: blockLimit)
        }
    }

    private static func decodeLiterals(_ input: inout Input, state: inout FrameState,
                                       blockLimit: Int) throws -> [UInt8] {
        let first = try input.readByte()
        let type = Int(first & 0x03)
        let sizeFormat = Int(first >> 2) & 0x03

        if type == 0 || type == 1 {
            // Raw / RLE：只有重建大小
            let size: Int
            switch sizeFormat {
            case 0, 2: size = Int(first >> 3)
            case 1: size = Int(first >> 4) + (Int(try input.readByte()) << 4)
            default: size = Int(first >> 4) + (Int(try input.readLE(2)) << 4)
            }
            guard size <= blockLimit else { throw ZstdError.corrupt("字面量大小超过块上限") }
            if type == 0 { return Array(try input.take(size)) }
            return [UInt8](repeating: try input.readByte(), count: size)
        }

        // Compressed / Treeless：重建大小与压缩大小
        let regenerated: Int
        let compressed: Int
        let streams: Int
        switch sizeFormat {
        case 0, 1:
            let h = Int(first) | (Int(try input.readLE(2)) << 8)
            regenerated = (h >> 4) & 0x3FF
            compressed = (h >> 14) & 0x3FF
            streams = sizeFormat == 0 ? 1 : 4
        case 2:
            let h = Int(first) | (Int(try input.readLE(3)) << 8)
            regenerated = (h >> 4) & 0x3FFF
            compressed = (h >> 18) & 0x3FFF
            streams = 4
        default:
            let h = Int(first) | (Int(try input.readLE(4)) << 8)
            regenerated = (h >> 4) & 0x3FFFF
            compressed = (h >> 22) & 0x3FFFF
            streams = 4
        }
        guard regenerated <= blockLimit else { throw ZstdError.corrupt("字面量大小超过块上限") }
        var payload = Input(try input.take(compressed))
        if type == 2 {
            state.huffman = try HuffmanTable.read(&payload)
        }
        guard let table = state.huffman else { throw ZstdError.corrupt("Treeless 字面量之前没有 Huffman 表") }
        return try table.decode(payload.rest, regenerated: regenerated, streams: streams)
    }

    // MARK: 序列

    private static func decodeSequences(_ input: inout Input, literals: UnsafeRawBufferPointer,
                                        state: inout FrameState, output: Output,
                                        frameStart: Int, blockLimit: Int) throws {
        let first = Int(try input.readByte())
        let count: Int
        if first < 128 {
            count = first
        } else if first < 255 {
            count = ((first - 128) << 8) + Int(try input.readByte())
        } else {
            count = Int(try input.readLE(2)) + 0x7F00
        }
        if count == 0 {
            guard input.isAtEnd else { throw ZstdError.corrupt("没有序列的块末尾有多余字节") }
            guard literals.count <= blockLimit else { throw ZstdError.corrupt("块解出的内容超过上限") }
            try output.append(literals)
            return
        }

        let modes = try input.readByte()
        guard modes & 0x03 == 0 else { throw ZstdError.corrupt("序列压缩模式的保留位不为 0") }
        state.literalLengths = try FSETable.select(mode: Int(modes >> 6), kind: .literalLength, input: &input,
                                                   previous: state.literalLengths)
        state.offsets = try FSETable.select(mode: Int(modes >> 4) & 0x03, kind: .offset, input: &input,
                                            previous: state.offsets)
        state.matchLengths = try FSETable.select(mode: Int(modes >> 2) & 0x03, kind: .matchLength, input: &input,
                                                 previous: state.matchLengths)
        guard let llTable = state.literalLengths, let ofTable = state.offsets, let mlTable = state.matchLengths
        else { throw ZstdError.corrupt("序列表缺失") }

        var bits = try BackwardBits(input.rest)
        var ll = FSEState(table: llTable, bits: &bits)
        var of = FSEState(table: ofTable, bits: &bits)
        var ml = FSEState(table: mlTable, bits: &bits)

        let blockStart = output.count
        var literalIndex = 0
        var repeats = state.repeatOffsets
        for index in 0..<count {
            let ofCode = Int(of.symbol)
            let mlCode = Int(ml.symbol)
            let llCode = Int(ll.symbol)
            guard ofCode <= 31 else { throw ZstdError.corrupt("偏移码 \(ofCode) 太大") }

            let offsetValue = (1 << ofCode) + Int(bits.read(ofCode))
            let matchLength = Codes.matchBase[mlCode] + Int(bits.read(Codes.matchExtraBits[mlCode]))
            let literalLength = Codes.literalBase[llCode]
                + Int(bits.read(Codes.literalExtraBits[llCode]))

            // 重复偏移（RFC 8878 3.1.2.5）
            let offset: Int
            if offsetValue > 3 {
                offset = offsetValue - 3
                repeats = (offset, repeats.0, repeats.1)
            } else {
                let index = literalLength == 0 ? offsetValue + 1 : offsetValue
                switch index {
                case 1:
                    offset = repeats.0
                case 2:
                    offset = repeats.1
                    repeats = (offset, repeats.0, repeats.2)
                case 3:
                    offset = repeats.2
                    repeats = (offset, repeats.0, repeats.1)
                default:
                    offset = repeats.0 - 1
                    guard offset > 0 else { throw ZstdError.corrupt("重复偏移为 0") }
                    repeats = (offset, repeats.0, repeats.1)
                }
            }

            guard literalLength <= literals.count - literalIndex else {
                throw ZstdError.corrupt("序列要的字面量比解出的多")
            }
            guard output.count - blockStart + literalLength + matchLength <= blockLimit else {
                throw ZstdError.corrupt("块解出的内容超过上限")
            }
            try output.append(UnsafeRawBufferPointer(rebasing: literals[literalIndex..<literalIndex + literalLength]))
            literalIndex += literalLength
            guard offset <= output.count - frameStart else { throw ZstdError.corrupt("偏移超出已解出的内容") }
            try output.copyMatch(offset: offset, length: matchLength)

            if index < count - 1 {
                ll.update(&bits)
                ml.update(&bits)
                of.update(&bits)
            }
        }
        guard bits.isExactlyConsumed else { throw ZstdError.corrupt("序列比特流没有恰好读完") }
        state.repeatOffsets = repeats

        let rest = literals.count - literalIndex
        guard output.count - blockStart + rest <= blockLimit else { throw ZstdError.corrupt("块解出的内容超过上限") }
        try output.append(UnsafeRawBufferPointer(rebasing: literals[literalIndex...]))
    }
}

// 以下是解码器内部用的类型，放在 Zstd 命名空间下，不占 Core 的顶层名字
extension Zstd {
    /// 一个帧内跨块保留的状态：上一张 Huffman 表、上一组 FSE 表、重复偏移
    struct FrameState {
        var huffman: HuffmanTable?
        var literalLengths: FSETable?
        var offsets: FSETable?
        var matchLengths: FSETable?
        var repeatOffsets = (1, 4, 8)
    }

    /// 序列码到长度的换算表（RFC 8878 3.1.1.3.2.1）
    enum Codes {
        static let literalBase: [Int] = Array(0...15) + [
            16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
            8192, 16384, 32768, 65536,
        ]
        static let literalExtraBits: [Int] = [Int](repeating: 0, count: 16) + [
            1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
            13, 14, 15, 16,
        ]
        static let matchBase: [Int] = Array(3...34) + [
            35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
            4099, 8195, 16387, 32771, 65539,
        ]
        static let matchExtraBits: [Int] = [Int](repeating: 0, count: 32) + [
            1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
            12, 13, 14, 15, 16,
        ]
    }

    // MARK: 输入与输出

    /// 带边界检查的顺序读取（越界抛 `.truncated`，不会崩溃）
    struct Input {
        private let buffer: UnsafeRawBufferPointer
        private(set) var position = 0

        init(_ buffer: UnsafeRawBufferPointer) { self.buffer = buffer }

        var isAtEnd: Bool { position >= buffer.count }
        var remaining: Int { buffer.count - position }
        /// 剩下的全部字节（不移动位置）
        var rest: UnsafeRawBufferPointer { UnsafeRawBufferPointer(rebasing: buffer[position...]) }

        mutating func readByte() throws -> UInt8 {
            guard position < buffer.count else { throw ZstdError.truncated }
            defer { position += 1 }
            return buffer[position]
        }

        /// 小端读 `count`（0…8）个字节
        mutating func readLE(_ count: Int) throws -> UInt64 {
            guard count <= remaining else { throw ZstdError.truncated }
            var value: UInt64 = 0
            for i in 0..<count { value |= UInt64(buffer[position + i]) << (8 * i) }
            position += count
            return value
        }

        mutating func take(_ count: Int) throws -> UnsafeRawBufferPointer {
            guard count >= 0, count <= remaining else { throw ZstdError.truncated }
            defer { position += count }
            return UnsafeRawBufferPointer(rebasing: buffer[position..<position + count])
        }

        mutating func skip(_ count: Int) throws { _ = try take(count) }
    }

    /// 解压结果：一整块连续内存，按需翻倍扩容，超过上限抛 `.outputTooLarge`
    final class Output {
        let limit: Int
        private(set) var count = 0
        private var capacity = 0
        private var storage: UnsafeMutablePointer<UInt8>?

        init(limit: Int) { self.limit = limit }
        deinit { storage?.deallocate() }

        func reserve(_ total: Int) {
            guard total > capacity else { return }
            let newStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: total)
            if let storage {
                newStorage.update(from: storage, count: count)
                storage.deallocate()
            }
            storage = newStorage
            capacity = total
        }

        /// 保证还能再写 `extra` 字节，返回写入位置
        private func grow(_ extra: Int) throws -> UnsafeMutablePointer<UInt8> {
            guard extra <= limit - count else { throw ZstdError.outputTooLarge(limit: limit) }
            if count + extra > capacity {
                reserve(min(limit, max(count + extra, capacity * 2, 64 << 10)))
            }
            return storage! + count
        }

        func append(_ bytes: UnsafeRawBufferPointer) throws {
            guard !bytes.isEmpty else { return }
            let target = try grow(bytes.count)
            UnsafeMutableRawPointer(target).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            count += bytes.count
        }

        func appendRepeating(_ byte: UInt8, count n: Int) throws {
            guard n > 0 else { return }
            try grow(n).initialize(repeating: byte, count: n)
            count += n
        }

        /// 从 `offset` 字节之前开始复制 `length` 字节（可与正在写的部分重叠；调用方保证 offset ≤ count）
        func copyMatch(offset: Int, length: Int) throws {
            guard length > 0 else { return }
            let target = try grow(length)
            let source = target - offset
            if offset >= length {
                target.update(from: source, count: length)
            } else {
                for i in 0..<length { target[i] = source[i] }
            }
            count += length
        }

        func withBytes<R>(from start: Int, _ body: (UnsafeRawBufferPointer) -> R) -> R {
            guard let storage, count > start else { return body(UnsafeRawBufferPointer(start: nil, count: 0)) }
            return body(UnsafeRawBufferPointer(start: storage + start, count: count - start))
        }

        func data() -> Data {
            guard let storage, count > 0 else { return Data() }
            // 把内存直接交给 Data，不再复制一份
            self.storage = nil
            capacity = 0
            return Data(bytesNoCopy: storage, count: count, deallocator: .custom { pointer, _ in
                pointer.assumingMemoryBound(to: UInt8.self).deallocate()
            })
        }
    }
}
