import Foundation

struct VorbisEntry: Equatable {
    var key: String
    var value: String
}

/// FLAC's tag block: a vendor string and a list of `KEY=value` lines in UTF-8.
/// Simpler than ID3 in every respect, which is why FLAC is the cheap format here
/// rather than the expensive one.
struct VorbisComment: Equatable {
    var vendor: String
    var entries: [VorbisEntry]

    /// Keys are case-insensitive per the specification, so compare them folded. The
    /// value comes back exactly as stored, for the same reason ID3 text does.
    func value(for key: String) -> String? {
        guard let hit = entries.first(where: { $0.key.uppercased() == key }),
              !hit.value.isEmpty else { return nil }
        return hit.value
    }

    mutating func set(_ key: String, _ value: String?) {
        let position = entries.firstIndex { $0.key.uppercased() == key }
        entries.removeAll { $0.key.uppercased() == key }
        guard let value else { return }
        entries.insert(VorbisEntry(key: key, value: value),
                       at: min(position ?? entries.count, entries.count))
    }

    var fields: TagFields {
        TagFields(title: value(for: "TITLE"),
                  artist: value(for: "ARTIST"),
                  album: value(for: "ALBUM"))
    }

    mutating func apply(_ edit: TagEdit) {
        let updated = fields.applying(edit)
        set("TITLE", updated.title)
        set("ARTIST", updated.artist)
        set("ALBUM", updated.album)
    }

    static func decode(_ data: Data) -> VorbisComment? {
        guard let vendorLength = data.littleEndianUInt32At(0),
              let vendorBytes = data.sliceAt(4, Int(vendorLength)) else { return nil }
        var offset = 4 + Int(vendorLength)
        guard let count = data.littleEndianUInt32At(offset) else { return nil }
        offset += 4

        var entries: [VorbisEntry] = []
        for _ in 0 ..< count {
            guard let length = data.littleEndianUInt32At(offset),
                  let raw = data.sliceAt(offset + 4, Int(length)) else { return nil }
            offset += 4 + Int(length)
            let line = String(decoding: raw, as: UTF8.self)
            guard let separator = line.firstIndex(of: "=") else { continue }
            entries.append(VorbisEntry(key: String(line[line.startIndex ..< separator]),
                                       value: String(line[line.index(after: separator)...])))
        }
        return VorbisComment(vendor: String(decoding: vendorBytes, as: UTF8.self),
                             entries: entries)
    }

    func encoded() -> Data {
        let vendorBytes = Data(vendor.utf8)
        var out = Data(ByteWriting.littleEndianUInt32(UInt32(vendorBytes.count)))
        out += vendorBytes
        out += Data(ByteWriting.littleEndianUInt32(UInt32(entries.count)))
        for entry in entries {
            let line = Data("\(entry.key)=\(entry.value)".utf8)
            out += Data(ByteWriting.littleEndianUInt32(UInt32(line.count)))
            out += line
        }
        return out
    }
}

struct FLACBlock: Equatable {
    var type: UInt8
    var data: Data

    static let vorbisComment: UInt8 = 4
}

/// Reads and rewrites the metadata block chain in a FLAC file.
///
/// Everything that is not the comment block is passed through untouched, which covers
/// `STREAMINFO`, `SEEKTABLE`, `CUESHEET`, `PICTURE` artwork and any `APPLICATION`
/// block a DJ tool has left behind.
enum FLACTagging {
    private struct Layout {
        var leadingID3: Data?
        var blocks: [FLACBlock]
        var audio: Data
    }

    static func readFields(_ file: Data) throws -> TagFields {
        let layout = try parse(file)
        guard let block = layout.blocks.first(where: { $0.type == FLACBlock.vorbisComment }),
              let comment = VorbisComment.decode(block.data) else { return TagFields() }
        return comment.fields
    }

    static func write(_ edit: TagEdit, into file: Data) throws -> Data {
        var layout = try parse(file)

        var comment = layout.blocks.first { $0.type == FLACBlock.vorbisComment }
            .flatMap { VorbisComment.decode($0.data) }
            ?? VorbisComment(vendor: "Crate", entries: [])
        comment.apply(edit)
        let encoded = FLACBlock(type: FLACBlock.vorbisComment, data: comment.encoded())

        if let i = layout.blocks.firstIndex(where: { $0.type == FLACBlock.vorbisComment }) {
            layout.blocks[i] = encoded
        } else {
            // STREAMINFO has to stay first; anything after it is fair game.
            layout.blocks.insert(encoded, at: min(1, layout.blocks.count))
        }

        // Some taggers prepend an ID3 tag to a FLAC. It is not part of the format, but
        // if it is there it is mirrored rather than left contradicting the real tag.
        if let existing = layout.leadingID3 {
            layout.leadingID3 = try mirroredID3(existing, fields: comment.fields)
        }

        return serialise(layout)
    }

    private static func parse(_ file: Data) throws -> Layout {
        var offset = 0
        var leadingID3: Data?
        if ID3v2.hasTag(file), let tag = try ID3v2.parse(file) {
            leadingID3 = file.sliceAt(0, tag.encodedByteCount)
            offset = tag.encodedByteCount
        }

        guard file.asciiAt(offset, 4) == "fLaC" else {
            throw TagWriteError.malformed("no fLaC marker")
        }
        offset += 4

        var blocks: [FLACBlock] = []
        while true {
            guard let header = file.byteAt(offset),
                  let size = file.bigEndianUInt24At(offset + 1),
                  let data = file.sliceAt(offset + 4, Int(size)) else {
                throw TagWriteError.malformed("truncated FLAC metadata block")
            }
            blocks.append(FLACBlock(type: header & 0x7F, data: data))
            offset += 4 + Int(size)
            if header & 0x80 != 0 { break }
            guard offset < file.count else {
                throw TagWriteError.malformed("FLAC metadata never reaches a final block")
            }
        }

        guard let audio = file.sliceAt(offset, file.count - offset) else {
            throw TagWriteError.malformed("FLAC metadata runs past the end of the file")
        }
        return Layout(leadingID3: leadingID3, blocks: blocks, audio: audio)
    }

    private static func mirroredID3(_ existing: Data, fields: TagFields) throws -> Data {
        guard var tag = try ID3v2.parse(existing) else { return existing }
        tag.setText(tag.titleFrameID, fields.title)
        tag.setText(tag.artistFrameID, fields.artist)
        tag.setText(tag.albumFrameID, fields.album)
        return Data(ID3v2.serialise(tag, preferredByteCount: tag.encodedByteCount))
    }

    private static func serialise(_ layout: Layout) -> Data {
        var out = layout.leadingID3 ?? Data()
        out += Data("fLaC".utf8)
        for (i, block) in layout.blocks.enumerated() {
            let isLast = i == layout.blocks.count - 1
            out += Data([block.type | (isLast ? 0x80 : 0)])
            out += Data(ByteWriting.bigEndianUInt24(UInt32(block.data.count)))
            out += block.data
        }
        return out + layout.audio
    }
}
