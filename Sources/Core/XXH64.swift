// XXH64（种子 0）：zstd 帧的内容校验和取它的低 32 位（RFC 8878 3.1.1，ticket 08）。

import Foundation

enum XXH64 {
    private static let prime1: UInt64 = 0x9E37_79B1_85EB_CA87
    private static let prime2: UInt64 = 0xC2B2_AE3D_27D4_EB4F
    private static let prime3: UInt64 = 0x1656_67B1_9E37_79F9
    private static let prime4: UInt64 = 0x85EB_CA77_C2B2_AE63
    private static let prime5: UInt64 = 0x27D4_EB2F_1656_67C5

    static func hash(_ bytes: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 {
        let count = bytes.count
        guard let base = bytes.baseAddress, count > 0 else { return avalanche(seed &+ prime5) }
        func read64(_ offset: Int) -> UInt64 {
            UInt64(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
        func read32(_ offset: Int) -> UInt64 {
            UInt64(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
        }

        var offset = 0
        var hash: UInt64
        if count >= 32 {
            var v1 = seed &+ prime1 &+ prime2
            var v2 = seed &+ prime2
            var v3 = seed
            var v4 = seed &- prime1
            while offset + 32 <= count {
                v1 = round(v1, read64(offset))
                v2 = round(v2, read64(offset + 8))
                v3 = round(v3, read64(offset + 16))
                v4 = round(v4, read64(offset + 24))
                offset += 32
            }
            hash = rotate(v1, 1) &+ rotate(v2, 7) &+ rotate(v3, 12) &+ rotate(v4, 18)
            hash = merge(hash, v1)
            hash = merge(hash, v2)
            hash = merge(hash, v3)
            hash = merge(hash, v4)
        } else {
            hash = seed &+ prime5
        }
        hash = hash &+ UInt64(count)

        while offset + 8 <= count {
            hash ^= round(0, read64(offset))
            hash = rotate(hash, 27) &* prime1 &+ prime4
            offset += 8
        }
        if offset + 4 <= count {
            hash ^= read32(offset) &* prime1
            hash = rotate(hash, 23) &* prime2 &+ prime3
            offset += 4
        }
        while offset < count {
            hash ^= UInt64(base.load(fromByteOffset: offset, as: UInt8.self)) &* prime5
            hash = rotate(hash, 11) &* prime1
            offset += 1
        }
        return avalanche(hash)
    }

    @inline(__always)
    private static func rotate(_ value: UInt64, _ bits: UInt64) -> UInt64 {
        (value << bits) | (value >> (64 - bits))
    }

    @inline(__always)
    private static func round(_ accumulator: UInt64, _ input: UInt64) -> UInt64 {
        rotate(accumulator &+ input &* prime2, 31) &* prime1
    }

    @inline(__always)
    private static func merge(_ hash: UInt64, _ value: UInt64) -> UInt64 {
        (hash ^ round(0, value)) &* prime1 &+ prime4
    }

    private static func avalanche(_ value: UInt64) -> UInt64 {
        var hash = value
        hash ^= hash >> 33
        hash = hash &* prime2
        hash ^= hash >> 29
        hash = hash &* prime3
        hash ^= hash >> 32
        return hash
    }
}
