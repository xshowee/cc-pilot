// zstd 解码器的熵编码部分（ticket 08）：反向比特流、FSE 表、Huffman 表。见 RFC 8878 第 4 节。

import Foundation

extension Zstd {
    /// 反向比特流：从最后一个字节的最高置位（起始标记）之下开始往前读。
    /// 读过开头时按 0 补齐、不报错（RFC 要求如此）；读完后用 `isExactlyConsumed` 检查是否恰好用完。
    struct BackwardBits {
        private let base: UnsafeRawPointer?
        private let count: Int
        /// 还没读的比特数；读过开头后为负
        private(set) var position: Int

        init(_ buffer: UnsafeRawBufferPointer) throws {
            guard let last = buffer.last, last != 0 else { throw ZstdError.corrupt("比特流缺少起始标记") }
            base = buffer.baseAddress
            count = buffer.count
            position = (count - 1) * 8 + (7 - last.leadingZeroBitCount)
        }

        var isExactlyConsumed: Bool { position == 0 }
        var isOverrun: Bool { position < 0 }

        /// 读 `n`（0…56）比特
        @inline(__always)
        mutating func read(_ n: Int) -> UInt64 {
            position -= n
            return bits(at: position, n)
        }

        /// 看接下来的 `n` 比特，不移动位置
        @inline(__always)
        func peek(_ n: Int) -> UInt64 { bits(at: position - n, n) }

        @inline(__always)
        mutating func consume(_ n: Int) { position -= n }

        @inline(__always)
        private func bits(at start: Int, _ n: Int) -> UInt64 {
            if n == 0 { return 0 }
            if start >= 0 { return load(start) & mask(n) }
            let available = n + start
            if available <= 0 { return 0 }
            return (load(0) & mask(available)) << UInt64(-start)
        }

        @inline(__always)
        private func mask(_ n: Int) -> UInt64 { (UInt64(1) << UInt64(n)) &- 1 }

        /// 从第 `bit` 比特起的至少 56 比特（越过末尾的部分为 0）
        @inline(__always)
        private func load(_ bit: Int) -> UInt64 {
            let byte = bit >> 3
            guard let base else { return 0 }
            var word: UInt64
            if byte + 8 <= count {
                word = UInt64(littleEndian: base.loadUnaligned(fromByteOffset: byte, as: UInt64.self))
            } else {
                word = 0
                for i in 0..<(count - byte) {
                    word |= UInt64(base.load(fromByteOffset: byte + i, as: UInt8.self)) << UInt64(8 * i)
                }
            }
            return word >> UInt64(bit & 7)
        }
    }

    // MARK: FSE

    struct FSEEntry {
        let symbol: UInt8
        let bits: UInt8
        let base: UInt16
    }

    /// FSE 解码表（RFC 8878 4.1）
    struct FSETable {
        let accuracyLog: Int
        let entries: [FSEEntry]

        enum Kind {
            case literalLength, offset, matchLength

            var maximumSymbol: Int {
                switch self {
                case .literalLength: return 35
                case .offset: return 31
                case .matchLength: return 52
                }
            }

            var maximumAccuracyLog: Int {
                switch self {
                case .literalLength, .matchLength: return 9
                case .offset: return 8
                }
            }

            var predefined: FSETable {
                switch self {
                case .literalLength: return FSETable.predefinedLiteralLengths
                case .offset: return FSETable.predefinedOffsets
                case .matchLength: return FSETable.predefinedMatchLengths
                }
            }
        }

        // 预定义分布（RFC 8878 3.1.1.3.2.2）
        static let predefinedLiteralLengths = try! FSETable(normalized: [
            4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
            -1, -1, -1, -1,
        ], accuracyLog: 6)
        static let predefinedMatchLengths = try! FSETable(normalized: [
            1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1,
        ], accuracyLog: 6)
        static let predefinedOffsets = try! FSETable(normalized: [
            1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
        ], accuracyLog: 5)

        /// 按序列压缩模式取表：0 预定义、1 RLE、2 FSE 压缩、3 重用上一张
        static func select(mode: Int, kind: Kind, input: inout Input, previous: FSETable?) throws -> FSETable {
            switch mode {
            case 0:
                return kind.predefined
            case 1:
                let symbol = try input.readByte()
                guard Int(symbol) <= kind.maximumSymbol else { throw ZstdError.corrupt("RLE 序列码超出范围") }
                return FSETable(accuracyLog: 0, entries: [FSEEntry(symbol: symbol, bits: 0, base: 0)])
            case 2:
                return try read(&input, maximumSymbol: kind.maximumSymbol, maximumAccuracyLog: kind.maximumAccuracyLog)
            default:
                guard let previous else { throw ZstdError.corrupt("重复模式之前没有可用的表") }
                return previous
            }
        }

        /// 读 FSE 表描述（RFC 8878 4.1.1），读完后 input 停在描述之后的字节边界
        static func read(_ input: inout Input, maximumSymbol: Int, maximumAccuracyLog: Int) throws -> FSETable {
            let bytes = input.rest
            var bitPosition = 0
            // 正向读；越过末尾的比特按 0 处理，最后再检查有没有真的越界
            func readBits(_ n: Int) -> Int {
                var value = 0
                for i in 0..<n {
                    let bit = bitPosition + i
                    if bit >> 3 < bytes.count, bytes[bit >> 3] & (1 << (bit & 7)) != 0 { value |= 1 << i }
                }
                bitPosition += n
                return value
            }

            let accuracyLog = 5 + readBits(4)
            guard accuracyLog <= maximumAccuracyLog else { throw ZstdError.corrupt("FSE 精度 \(accuracyLog) 超出范围") }
            var remaining = 1 << accuracyLog
            var normalized: [Int] = []
            while remaining > 0 {
                guard normalized.count <= maximumSymbol else { throw ZstdError.corrupt("FSE 分布的符号太多") }
                let width = (Int.bitWidth - (remaining + 1).leadingZeroBitCount)  // highbit(remaining + 1) + 1
                var value = readBits(width)
                let lowerMask = (1 << (width - 1)) - 1
                let threshold = (1 << width) - 1 - (remaining + 1)
                if value & lowerMask < threshold {
                    bitPosition -= 1
                    value &= lowerMask
                } else if value > lowerMask {
                    value -= threshold
                }
                let probability = value - 1
                remaining -= abs(probability)
                normalized.append(probability)
                if probability == 0 {
                    // 概率为 0 后面跟 2 比特的重复次数，3 表示还要再读
                    while true {
                        let repeatCount = readBits(2)
                        guard normalized.count + repeatCount <= maximumSymbol + 1 else {
                            throw ZstdError.corrupt("FSE 分布的符号太多")
                        }
                        normalized += [Int](repeating: 0, count: repeatCount)
                        if repeatCount != 3 { break }
                    }
                }
            }
            guard remaining == 0 else { throw ZstdError.corrupt("FSE 分布之和不对") }
            let byteCount = (bitPosition + 7) / 8
            guard byteCount <= bytes.count else { throw ZstdError.truncated }
            try input.skip(byteCount)
            return try FSETable(normalized: normalized, accuracyLog: accuracyLog)
        }

        private init(accuracyLog: Int, entries: [FSEEntry]) {
            self.accuracyLog = accuracyLog
            self.entries = entries
        }

        /// 由归一化分布建解码表（RFC 8878 4.1.1）；-1 表示"小于 1"
        init(normalized: [Int], accuracyLog: Int) throws {
            let size = 1 << accuracyLog
            var symbols = [UInt8](repeating: 0, count: size)
            var next = [Int](repeating: 0, count: normalized.count)
            var high = size
            for (symbol, probability) in normalized.enumerated() where probability == -1 {
                high -= 1
                symbols[high] = UInt8(symbol)
                next[symbol] = 1
            }
            let step = (size >> 1) + (size >> 3) + 3
            let mask = size - 1
            var position = 0
            for (symbol, probability) in normalized.enumerated() where probability > 0 {
                next[symbol] = probability
                for _ in 0..<probability {
                    symbols[position] = UInt8(symbol)
                    repeat { position = (position + step) & mask } while position >= high
                }
            }
            guard position == 0 else { throw ZstdError.corrupt("FSE 分布无法铺满表") }

            var entries: [FSEEntry] = []
            entries.reserveCapacity(size)
            for symbol in symbols {
                let state = next[Int(symbol)]
                next[Int(symbol)] += 1
                let bits = accuracyLog - (Int.bitWidth - 1 - state.leadingZeroBitCount)
                entries.append(FSEEntry(symbol: symbol, bits: UInt8(bits), base: UInt16((state << bits) - size)))
            }
            self.accuracyLog = accuracyLog
            self.entries = entries
        }
    }

    /// 一个 FSE 解码状态
    struct FSEState {
        private let entries: [FSEEntry]
        private var state: Int

        init(table: FSETable, bits: inout BackwardBits) {
            entries = table.entries
            state = Int(bits.read(table.accuracyLog))
        }

        @inline(__always)
        var symbol: UInt8 { entries[state].symbol }

        @inline(__always)
        mutating func update(_ bits: inout BackwardBits) {
            let entry = entries[state]
            state = Int(entry.base) + Int(bits.read(Int(entry.bits)))
        }
    }

    // MARK: Huffman

    /// Huffman 字面量解码表（RFC 8878 4.2）：按 maxBits 比特直接查表，每项 = 符号 | (码长 << 8)
    struct HuffmanTable {
        static let maximumBits = 11

        let maxBits: Int
        let entries: [UInt16]

        /// 读 Huffman 树描述
        static func read(_ input: inout Input) throws -> HuffmanTable {
            let header = Int(try input.readByte())
            var weights: [UInt8]
            if header >= 128 {
                // 直接表示：每个权重 4 比特
                let count = header - 127
                let bytes = try input.take((count + 1) / 2)
                weights = (0..<count).map { i in i % 2 == 0 ? bytes[i / 2] >> 4 : bytes[i / 2] & 0x0F }
            } else {
                weights = try decodeWeights(try input.take(header))
            }
            return try HuffmanTable(weights: weights)
        }

        /// FSE 压缩的权重：两个交错的状态共用一条反向比特流
        private static func decodeWeights(_ buffer: UnsafeRawBufferPointer) throws -> [UInt8] {
            var input = Input(buffer)
            let table = try FSETable.read(&input, maximumSymbol: maximumBits + 1, maximumAccuracyLog: 6)
            var bits = try BackwardBits(input.rest)
            var first = FSEState(table: table, bits: &bits)
            var second = FSEState(table: table, bits: &bits)
            var weights: [UInt8] = []
            while true {
                guard weights.count < 254 else { throw ZstdError.corrupt("Huffman 权重太多") }
                weights.append(first.symbol)
                first.update(&bits)
                if bits.isOverrun {
                    weights.append(second.symbol)
                    break
                }
                weights.append(second.symbol)
                second.update(&bits)
                if bits.isOverrun {
                    weights.append(first.symbol)
                    break
                }
            }
            return weights
        }

        /// 由权重建表；最后一个符号的权重不写在描述里，由总和补成 2 的幂推出
        init(weights explicit: [UInt8]) throws {
            guard explicit.count <= 255 else { throw ZstdError.corrupt("Huffman 权重太多") }
            var total = 0
            for weight in explicit where weight > 0 {
                guard Int(weight) <= HuffmanTable.maximumBits else { throw ZstdError.corrupt("Huffman 权重超出范围") }
                total += 1 << (Int(weight) - 1)
            }
            guard total > 0 else { throw ZstdError.corrupt("Huffman 权重全为 0") }
            let maxBits = Int.bitWidth - total.leadingZeroBitCount  // highbit(total) + 1
            guard maxBits <= HuffmanTable.maximumBits else { throw ZstdError.corrupt("Huffman 码长超出范围") }
            let leftover = (1 << maxBits) - total
            guard leftover & (leftover - 1) == 0 else { throw ZstdError.corrupt("Huffman 权重之和不对") }
            let weights = explicit + [UInt8(Int.bitWidth - leftover.leadingZeroBitCount)]

            // 码长 = maxBits + 1 - 权重；码长越长（权重越小）的符号排在表的越前面，同码长按符号顺序
            let lengths = weights.map { $0 == 0 ? 0 : maxBits + 1 - Int($0) }
            var rankCount = [Int](repeating: 0, count: maxBits + 1)
            for length in lengths { rankCount[length] += 1 }
            var rankStart = [Int](repeating: 0, count: maxBits + 2)
            // rankStart[length]：该码长的第一项位置
            var position = 0
            for length in stride(from: maxBits, through: 1, by: -1) {
                rankStart[length] = position
                position += rankCount[length] << (maxBits - length)
            }
            let size = 1 << maxBits
            guard position == size else { throw ZstdError.corrupt("Huffman 表不完整") }
            var entries = [UInt16](repeating: 0, count: size)
            for (symbol, length) in lengths.enumerated() where length > 0 {
                let start = rankStart[length]
                let span = 1 << (maxBits - length)
                let entry = UInt16(symbol) | UInt16(length) << 8
                for i in start..<start + span { entries[i] = entry }
                rankStart[length] = start + span
            }
            self.maxBits = maxBits
            self.entries = entries
        }

        /// 解出 `regenerated` 个字面量；`streams` 为 1 或 4（4 流时开头有 6 字节跳转表）
        func decode(_ buffer: UnsafeRawBufferPointer, regenerated: Int, streams: Int) throws -> [UInt8] {
            var output = [UInt8](repeating: 0, count: regenerated)
            try output.withUnsafeMutableBufferPointer { output in
                if streams == 1 {
                    try decodeStream(buffer, into: output)
                    return
                }
                var input = Input(buffer)
                let sizes = [Int(try input.readLE(2)), Int(try input.readLE(2)), Int(try input.readLE(2))]
                let segment = (regenerated + 3) / 4
                guard 3 * segment <= regenerated else { throw ZstdError.corrupt("4 流字面量太短") }
                for (index, size) in sizes.enumerated() {
                    let start = index * segment
                    try decodeStream(try input.take(size), into: UnsafeMutableBufferPointer(rebasing: output[start..<start + segment]))
                }
                try decodeStream(input.rest, into: UnsafeMutableBufferPointer(rebasing: output[(3 * segment)...]))
            }
            return output
        }

        private func decodeStream(_ buffer: UnsafeRawBufferPointer, into output: UnsafeMutableBufferPointer<UInt8>) throws {
            var bits = try BackwardBits(buffer)
            let maxBits = self.maxBits
            try entries.withUnsafeBufferPointer { table in
                for i in 0..<output.count {
                    let entry = table[Int(bits.peek(maxBits))]
                    output[i] = UInt8(truncatingIfNeeded: entry)
                    bits.consume(Int(entry >> 8))
                }
                guard bits.isExactlyConsumed else { throw ZstdError.corrupt("Huffman 比特流没有恰好读完") }
            }
        }
    }
}
