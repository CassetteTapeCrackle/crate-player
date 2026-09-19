import Foundation

/// One frame, kept as raw bytes.
///
/// The payload is never interpreted unless it is one of the three frames Crate
/// edits. This collection carries Serato cue points and beatgrids in `GEOB` frames
/// sitting directly beside the title frame, and re-encoding a frame we only half
/// understand is exactly how those get destroyed.
struct ID3Frame: Equatable {
    var id: String
    var flags: UInt16       // always 0 in v2.2, which has no frame flags
    var payload: Data
}

/// An ID3v2 tag parsed far enough to edit three frames and put everything else back.
struct ID3Tag: Equatable {
    /// 2, 3 or 4, and preserved across a write. A v2.2 tag cannot be upgraded,
    /// because its unknown frames carry 3-character identifiers with no 4-character
    /// equivalent to map onto, so upgrading would mean dropping them.
    var majorVersion: UInt8
    var revision: UInt8
    var frames: [ID3Frame]

    /// Bytes the tag occupied on disk, header and footer included.
    var encodedByteCount: Int

    var titleFrameID: String { majorVersion == 2 ? "TT2" : "TIT2" }
    var artistFrameID: String { majorVersion == 2 ? "TP1" : "TPE1" }
    var albumFrameID: String { majorVersion == 2 ? "TAL" : "TALB" }

    var fields: TagFields {
        TagFields(title: text(for: titleFrameID),
                  artist: text(for: artistFrameID),
                  album: text(for: albumFrameID))
    }

    func text(for id: String) -> String? {
        guard let frame = frames.first(where: { $0.id == id }) else { return nil }
        return ID3v2.decodeText(frame.payload)
    }

    mutating func apply(_ edit: TagEdit) {
        let updated = fields.applying(edit)
        setText(titleFrameID, updated.title)
        setText(artistFrameID, updated.artist)
        setText(albumFrameID, updated.album)
    }

    /// Replaces the frame in place so its position in the tag is kept, or removes
    /// every copy when the value is gone. Flags are reset because a rewritten payload
    /// is no longer compressed, encrypted or unsynchronised, whatever the old ones
    /// claimed.
    mutating func setText(_ id: String, _ value: String?) {
        let position = frames.firstIndex { $0.id == id }
        frames.removeAll { $0.id == id }
        guard let value else { return }
        let frame = ID3Frame(id: id, flags: 0,
                             payload: ID3v2.encodeText(value, major: majorVersion))
        frames.insert(frame, at: min(position ?? frames.count, frames.count))
    }
}

/// Parser and serialiser for ID3v2.2, v2.3 and v2.4.
///
/// All three versions are supported deliberately. v2.2 is obsolete and this library
/// may well contain none, but the frame header is 6 bytes against v2.3's 10, so a
/// parser that ignored the version byte would not merely miss a field: it would
/// misread every frame length in the tag and write back garbage.
enum ID3v2 {
    static let magic: [UInt8] = Array("ID3".utf8)
    static let headerLength = 10

    static func hasTag(_ data: Data) -> Bool {
        guard let head = data.sliceAt(0, 3) else { return false }
        return [UInt8](head) == magic
    }

    /// Parses the tag starting at offset 0 of `data`. Returns nil when there is no
    /// tag there, and throws when there is one that cannot be fully accounted for.
    static func parse(_ data: Data) throws -> ID3Tag? {
        guard hasTag(data) else { return nil }
        guard let major = data.byteAt(3), let revision = data.byteAt(4),
              let flags = data.byteAt(5), let bodySize = data.syncsafeUInt32At(6)
        else { throw TagWriteError.malformed("truncated ID3 header") }

        guard (2...4).contains(major) else {
            throw TagWriteError.malformed("ID3v2.\(major) is not a version we can write")
        }
        if major == 2, flags & 0x40 != 0 {
            throw TagWriteError.malformed("compressed ID3v2.2 tags have no defined scheme")
        }

        let hasFooter = major == 4 && flags & 0x10 != 0
        let encodedByteCount = headerLength + Int(bodySize) + (hasFooter ? headerLength : 0)

        guard let rawBody = data.sliceAt(headerLength, Int(bodySize)) else {
            throw TagWriteError.malformed("ID3 tag claims \(bodySize) bytes, file has fewer")
        }

        // v2.2 and v2.3 unsynchronise the whole tag body; v2.4 moved it to the frame
        // level, where the per-frame flag is authoritative.
        var body = [UInt8](rawBody)
        if major < 4, flags & 0x80 != 0 { body = deUnsynchronise(body) }

        // The extended header is optional and holds a CRC over the frames, which any
        // edit would invalidate. Drop it and clear the flag rather than ship a lie.
        var start = 0
        if flags & 0x40 != 0 {
            if major == 3 {
                guard body.count >= 4 else {
                    throw TagWriteError.malformed("truncated v2.3 extended header")
                }
                start = 4 + Int(body[0...3].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            } else if major == 4 {
                guard body.count >= 4, body[0...3].allSatisfy({ $0 < 0x80 }) else {
                    throw TagWriteError.malformed("truncated v2.4 extended header")
                }
                start = Int(body[0...3].reduce(UInt32(0)) { ($0 << 7) | UInt32($1) })
            }
            guard start <= body.count else {
                throw TagWriteError.malformed("extended header runs past the tag")
            }
        }
        let frameArea = Array(body[start...])

        let frames: [ID3Frame]
        if major == 4 {
            // iTunes and older Lame wrote v2.4 frame sizes as plain big-endian rather
            // than syncsafe. Try the spec first, then the common bug, rather than
            // refusing a file that every other player reads.
            if let parsed = walkFrames(frameArea, major: major, syncsafeSizes: true) {
                frames = parsed
            } else if let parsed = walkFrames(frameArea, major: major, syncsafeSizes: false) {
                frames = parsed
            } else {
                throw TagWriteError.malformed("v2.4 frame sizes are inconsistent")
            }
        } else {
            guard let parsed = walkFrames(frameArea, major: major, syncsafeSizes: false) else {
                throw TagWriteError.malformed("v2.\(major) frame list does not add up")
            }
            frames = parsed
        }

        return ID3Tag(majorVersion: major, revision: revision,
                      frames: frames, encodedByteCount: encodedByteCount)
    }

    /// Walks the frame list, returning nil when it does not add up so the caller can
    /// retry under different size rules. Refusing here is what keeps a misparse from
    /// reaching the writer.
    private static func walkFrames(_ body: [UInt8], major: UInt8,
                                   syncsafeSizes: Bool) -> [ID3Frame]? {
        let headerSize = major == 2 ? 6 : 10
        let idLength = major == 2 ? 3 : 4
        var frames: [ID3Frame] = []
        var i = 0

        while i + headerSize <= body.count {
            if body[i] == 0 { break }       // padding begins

            let idBytes = Array(body[i ..< i + idLength])
            guard idBytes.allSatisfy(isFrameIDByte) else { return nil }

            var size = 0
            var flags: UInt16 = 0
            if major == 2 {
                size = body[(i + 3)...(i + 5)].reduce(0) { ($0 << 8) | Int($1) }
            } else {
                let sizeBytes = body[(i + 4)...(i + 7)]
                if syncsafeSizes {
                    guard sizeBytes.allSatisfy({ $0 < 0x80 }) else { return nil }
                    size = sizeBytes.reduce(0) { ($0 << 7) | Int($1) }
                } else {
                    size = sizeBytes.reduce(0) { ($0 << 8) | Int($1) }
                }
                flags = UInt16(body[i + 8]) << 8 | UInt16(body[i + 9])
            }

            guard size >= 0, i + headerSize + size <= body.count else { return nil }
            var payload = Data(body[(i + headerSize) ..< (i + headerSize + size)])

            // v2.4 unsynchronisation is per frame. Undo it here and clear the flag,
            // because the serialiser never writes unsynchronised.
            if major == 4, flags & 0x0002 != 0 {
                payload = Data(deUnsynchronise([UInt8](payload)))
                flags &= ~UInt16(0x0002)
            }

            frames.append(ID3Frame(id: String(decoding: idBytes, as: UTF8.self),
                                   flags: flags, payload: payload))
            i += headerSize + size
        }

        // Anything left has to be padding. A non-zero byte here means the walk lost
        // sync somewhere behind us and the frames cannot be trusted.
        guard body[i...].allSatisfy({ $0 == 0 }) else { return nil }
        return frames
    }

    private static func isFrameIDByte(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39)
    }

    /// Undoes the `FF 00` escaping that keeps tag bytes from looking like an MPEG
    /// sync word. Copying raw payloads out of an unsynchronised tag without doing
    /// this first is the classic way to corrupt one.
    static func deUnsynchronise(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.contains(0xFF) else { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            out.append(bytes[i])
            if bytes[i] == 0xFF, i + 1 < bytes.count, bytes[i + 1] == 0x00 {
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    /// Serialises a tag with every header flag cleared: no unsynchronisation, no
    /// extended header, no footer. All three are optional, and none of them can be
    /// carried across an edit without either recomputing a CRC or re-escaping bytes
    /// for no gain.
    ///
    /// `preferredByteCount` keeps the tag the size it already was when the new frames
    /// still fit, so an edit does not change the file's length.
    static func serialise(_ tag: ID3Tag, preferredByteCount: Int? = nil) -> [UInt8] {
        var block: [UInt8] = []
        for frame in tag.frames {
            let idLength = tag.majorVersion == 2 ? 3 : 4
            var id = Array(frame.id.utf8.prefix(idLength))
            while id.count < idLength { id.append(0x20) }
            block += id

            let size = UInt32(frame.payload.count)
            if tag.majorVersion == 2 {
                block += ByteWriting.bigEndianUInt24(size)
            } else {
                block += tag.majorVersion == 4
                    ? ByteWriting.syncsafeUInt32(size)
                    : ByteWriting.bigEndianUInt32(size)
                block += [UInt8(truncatingIfNeeded: frame.flags >> 8),
                          UInt8(truncatingIfNeeded: frame.flags)]
            }
            block += [UInt8](frame.payload)
        }

        let minimumBody = block.count
        var bodySize = minimumBody + 1024
        if let preferred = preferredByteCount, preferred - headerLength >= minimumBody {
            bodySize = preferred - headerLength
        }

        var out = magic
        out += [tag.majorVersion, tag.revision, 0]
        out += ByteWriting.syncsafeUInt32(UInt32(bodySize))
        out += block
        out += [UInt8](repeating: 0, count: bodySize - minimumBody)
        return out
    }

    // MARK: Text frames

    /// Decodes a text frame payload. All four encodings are accepted on read even
    /// where the version does not permit them, because files in the wild use them.
    static func decodeText(_ payload: Data) -> String? {
        guard let encoding = payload.byteAt(0),
              let raw = payload.sliceAt(1, payload.count - 1) else { return nil }
        let bytes = [UInt8](raw)

        switch encoding {
        case 0: return firstValue(String(bytes.map { Character(UnicodeScalar($0)) }))
        case 1: return decodeUTF16(bytes, bigEndian: false)
        case 2: return decodeUTF16(bytes, bigEndian: true)
        case 3: return firstValue(String(decoding: bytes, as: UTF8.self))
        default: return nil
        }
    }

    private static func decodeUTF16(_ bytes: [UInt8], bigEndian: Bool) -> String? {
        var b = bytes
        var big = bigEndian
        if b.count >= 2 {
            if b[0] == 0xFF, b[1] == 0xFE { big = false; b.removeFirst(2) }
            else if b[0] == 0xFE, b[1] == 0xFF { big = true; b.removeFirst(2) }
        }
        if b.count % 2 != 0 { b.removeLast() }
        var units: [UInt16] = []
        units.reserveCapacity(b.count / 2)
        for i in stride(from: 0, to: b.count, by: 2) {
            units.append(big ? UInt16(b[i]) << 8 | UInt16(b[i + 1])
                             : UInt16(b[i + 1]) << 8 | UInt16(b[i]))
        }
        return firstValue(String(decoding: units, as: UTF16.self))
    }

    /// Text frames are null-terminated, and v2.4 separates multiple values with nulls
    /// too. Crate shows one value, so take the first.
    ///
    /// Nothing is trimmed. Deciding a value is not worth showing belongs to
    /// `MetadataStore.visible`, and doing it here instead loses real data twice over:
    /// a title legitimately ending in a space comes back shortened, and the titles in
    /// this collection built entirely from bidi and zero-width marks lose characters,
    /// because Foundation counts some of those as whitespace.
    private static func firstValue(_ s: String) -> String? {
        let head = s.split(separator: "\0", omittingEmptySubsequences: false).first
            .map(String.init) ?? s
        return head.isEmpty ? nil : head
    }

    /// Prefers ISO-8859-1, which every player ever built can read, and steps up only
    /// when the string will not fit in it.
    static func encodeText(_ value: String, major: UInt8) -> Data {
        if let latin1 = value.data(using: .isoLatin1) {
            return Data([0]) + latin1
        }
        if major >= 4 {
            return Data([3]) + Data(value.utf8)
        }
        // v2.2 and v2.3 have no UTF-8, so UTF-16 with a byte order mark it is.
        var out: [UInt8] = [1, 0xFF, 0xFE]
        for unit in Array(value.utf16) {
            out.append(UInt8(truncatingIfNeeded: unit))
            out.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        return Data(out)
    }
}

/// The 128-byte tag some mp3s still carry at the tail.
///
/// Mirrored when present and never created, the same rule the WAVE writer applies to
/// `LIST`/`INFO`. A stale v1 tag disagreeing with the real one surfaces as a phantom
/// bug in whichever other player happens to prefer it.
enum ID3v1 {
    static let length = 128
    private static let magic: [UInt8] = Array("TAG".utf8)

    static func isPresent(in file: Data) -> Bool {
        guard file.count >= length,
              let head = file.sliceAt(file.count - length, 3) else { return false }
        return [UInt8](head) == magic
    }

    /// Rewrites title, artist and album inside an existing 128-byte tag, leaving year,
    /// comment, track and genre exactly as they were.
    static func updated(_ tag: Data, with fields: TagFields) -> Data {
        var bytes = [UInt8](tag)
        guard bytes.count == length else { return tag }
        write(fields.title, into: &bytes, at: 3)
        write(fields.artist, into: &bytes, at: 33)
        write(fields.album, into: &bytes, at: 63)
        return Data(bytes)
    }

    private static func write(_ value: String?, into bytes: inout [UInt8], at offset: Int) {
        var field = [UInt8](repeating: 0, count: 30)
        if let value, let latin1 = value.data(using: .isoLatin1, allowLossyConversion: true) {
            for (i, b) in latin1.prefix(30).enumerated() { field[i] = b }
        }
        bytes.replaceSubrange(offset ..< (offset + 30), with: field)
    }
}
