import Foundation

/// Offset-based reads over `Data`, safe on slices.
///
/// A `Data` slice keeps its parent's indices, so `slice[0]` traps and `slice[i]` reads
/// the wrong byte. Every read here is relative to the slice's own start and returns
/// nil rather than trapping when it would run past the end, which is what lets the
/// parsers treat a truncated file as malformed instead of crashing on it.
extension Data {
    func byteAt(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[startIndex + offset]
    }

    func sliceAt(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset &+ length <= count else { return nil }
        let from = startIndex + offset
        return self[from ..< (from + length)]
    }

    func asciiAt(_ offset: Int, _ length: Int) -> String? {
        guard let bytes = sliceAt(offset, length) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    func bigEndianUInt32At(_ offset: Int) -> UInt32? {
        guard let b = sliceAt(offset, 4) else { return nil }
        return b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    func bigEndianUInt24At(_ offset: Int) -> UInt32? {
        guard let b = sliceAt(offset, 3) else { return nil }
        return b.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    func littleEndianUInt32At(_ offset: Int) -> UInt32? {
        guard let b = sliceAt(offset, 4) else { return nil }
        return b.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// ID3's syncsafe integer: seven bits per byte, so the encoded form can never
    /// contain a run that looks like an MPEG sync word.
    func syncsafeUInt32At(_ offset: Int) -> UInt32? {
        guard let b = sliceAt(offset, 4) else { return nil }
        guard b.allSatisfy({ $0 < 0x80 }) else { return nil }
        return b.reduce(UInt32(0)) { ($0 << 7) | UInt32($1) }
    }
}

enum ByteWriting {
    static func bigEndianUInt32(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
         UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }

    static func bigEndianUInt24(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8),
         UInt8(truncatingIfNeeded: v)]
    }

    static func littleEndianUInt32(_ v: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
         UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
    }

    static func syncsafeUInt32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F),
         UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
    }
}
