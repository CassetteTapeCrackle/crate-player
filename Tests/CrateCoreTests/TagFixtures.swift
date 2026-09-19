import Foundation
@testable import CrateCore

/// Fixtures are built from the format specifications rather than copied from the
/// library, so the suite covers shapes this collection may not contain. A writer that
/// is correct only for the files it was developed against corrupts the first stranger
/// it meets.
enum TagFixtures {

    // MARK: ID3

    /// A text frame payload in ISO-8859-1, the encoding the writer prefers.
    static func latin1Text(_ s: String) -> Data {
        Data([0]) + s.data(using: .isoLatin1)!
    }

    static func utf16Text(_ s: String) -> Data {
        var out: [UInt8] = [1, 0xFF, 0xFE]
        for unit in Array(s.utf16) {
            out.append(UInt8(truncatingIfNeeded: unit))
            out.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        return Data(out)
    }

    /// Serialises a tag by hand so the tests never depend on the writer to build
    /// their own input.
    static func id3Tag(major: UInt8, frames: [(String, Data)],
                       padding: Int = 64, unsynchronised: Bool = false,
                       syncsafeFrameSizes: Bool = true,
                       footer: Bool = false) -> Data {
        var block: [UInt8] = []
        for (id, payload) in frames {
            let idLength = major == 2 ? 3 : 4
            var idBytes = Array(id.utf8.prefix(idLength))
            while idBytes.count < idLength { idBytes.append(0x20) }
            block += idBytes
            let size = UInt32(payload.count)
            if major == 2 {
                block += ByteWriting.bigEndianUInt24(size)
            } else {
                block += (major == 4 && syncsafeFrameSizes)
                    ? ByteWriting.syncsafeUInt32(size)
                    : ByteWriting.bigEndianUInt32(size)
                block += [0, 0]
            }
            block += [UInt8](payload)
        }
        block += [UInt8](repeating: 0, count: padding)

        if unsynchronised { block = unsynchronise(block) }

        var flags: UInt8 = 0
        if unsynchronised { flags |= 0x80 }
        if footer { flags |= 0x10 }

        var out = Array("ID3".utf8)
        out += [major, 0, flags]
        out += ByteWriting.syncsafeUInt32(UInt32(block.count))
        out += block
        if footer {
            out += Array("3DI".utf8)
            out += [major, 0, flags]
            out += ByteWriting.syncsafeUInt32(UInt32(block.count))
        }
        return Data(out)
    }

    /// The inverse of the parser's de-unsynchronisation: insert a zero after any FF
    /// that would otherwise look like the start of an MPEG sync word.
    static func unsynchronise(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for (i, b) in bytes.enumerated() {
            out.append(b)
            guard b == 0xFF else { continue }
            let next = i + 1 < bytes.count ? bytes[i + 1] : 0x00
            if next >= 0xE0 || next == 0x00 { out.append(0x00) }
        }
        return out
    }

    /// Stands in for Serato's cue point and beatgrid frames. The bytes are arbitrary
    /// and that is the point: the writer must not understand them and must not touch
    /// them.
    static let seratoGEOB = Data([
        0x00, 0x61, 0x70, 0x70, 0x6C, 0x69, 0x63, 0x61, 0x74, 0x69, 0x6F, 0x6E,
        0x2F, 0x6F, 0x63, 0x74, 0x65, 0x74, 0x2D, 0x73, 0x74, 0x72, 0x65, 0x61,
        0x6D, 0x00, 0x00, 0x53, 0x65, 0x72, 0x61, 0x74, 0x6F, 0x20, 0x4D, 0x61,
        0x72, 0x6B, 0x65, 0x72, 0x73, 0x32, 0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0x01,
    ])

    static let id3v1Tag: Data = {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes.replaceSubrange(0..<3, with: Array("TAG".utf8))
        bytes.replaceSubrange(3..<7, with: Array("Old!".utf8))     // title
        bytes.replaceSubrange(93..<97, with: Array("1999".utf8))   // year, must survive
        bytes[127] = 17                                            // genre, must survive
        return Data(bytes)
    }()

    // MARK: Containers

    /// Bytes that look like MPEG audio, including an FF E3 sync word so any accidental
    /// unsynchronisation shows up as a length change.
    static let mp3Audio = Data([0xFF, 0xE3, 0x18, 0xC4] + [UInt8](repeating: 0x5A, count: 512))

    static func mp3(tag: Data?, audio: Data = mp3Audio, v1: Data? = nil) -> Data {
        (tag ?? Data()) + audio + (v1 ?? Data())
    }

    static func chunk(_ id: String, _ payload: Data, littleEndian: Bool) -> Data {
        var out = Data(id.utf8)
        out += Data(littleEndian ? ByteWriting.littleEndianUInt32(UInt32(payload.count))
                                 : ByteWriting.bigEndianUInt32(UInt32(payload.count)))
        out += payload
        if payload.count % 2 == 1 { out += Data([0]) }
        return out
    }

    static func aiff(_ chunks: [(String, Data)]) -> Data {
        var body = Data("AIFF".utf8)
        for (id, payload) in chunks { body += chunk(id, payload, littleEndian: false) }
        return Data("FORM".utf8)
            + Data(ByteWriting.bigEndianUInt32(UInt32(body.count))) + body
    }

    static func wave(_ chunks: [(String, Data)]) -> Data {
        var body = Data("WAVE".utf8)
        for (id, payload) in chunks { body += chunk(id, payload, littleEndian: true) }
        return Data("RIFF".utf8)
            + Data(ByteWriting.littleEndianUInt32(UInt32(body.count))) + body
    }

    static func infoList(_ entries: [(String, String)]) -> Data {
        var out = Data("INFO".utf8)
        for (id, value) in entries {
            out += chunk(id, Data(value.utf8) + Data([0]), littleEndian: true)
        }
        return out
    }

    static let sampleAudioChunk = Data([UInt8](repeating: 0xA7, count: 300))

    // MARK: FLAC

    static let streamInfo = Data([UInt8](repeating: 0x11, count: 34))
    static let flacPicture = Data([0x00, 0x00, 0x00, 0x03] + [UInt8](repeating: 0xC3, count: 40))
    static let flacAudio = Data([UInt8](repeating: 0x6B, count: 256))

    static func vorbisBlock(vendor: String, _ entries: [(String, String)]) -> Data {
        let v = Data(vendor.utf8)
        var out = Data(ByteWriting.littleEndianUInt32(UInt32(v.count))) + v
        out += Data(ByteWriting.littleEndianUInt32(UInt32(entries.count)))
        for (k, value) in entries {
            let line = Data("\(k)=\(value)".utf8)
            out += Data(ByteWriting.littleEndianUInt32(UInt32(line.count))) + line
        }
        return out
    }

    static func flac(blocks: [(UInt8, Data)], audio: Data = flacAudio,
                     leadingID3: Data? = nil) -> Data {
        var out = leadingID3 ?? Data()
        out += Data("fLaC".utf8)
        for (i, block) in blocks.enumerated() {
            let (type, data) = block
            out += Data([type | (i == blocks.count - 1 ? 0x80 : 0)])
            out += Data(ByteWriting.bigEndianUInt24(UInt32(data.count)))
            out += data
        }
        return out + audio
    }

    // MARK: Disk

    static func write(_ data: Data, as name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crate-tag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    static func cleanUp(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
