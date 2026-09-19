import Foundation

/// Where an ID3v2 tag sits in a file. One frame codec serves all three, which is what
/// makes mp3, aiff and wav a single backend rather than three.
enum ID3Container {
    case bare       // mp3: the tag is the start of the file
    case aiff       // an `ID3 ` chunk inside a FORM, big-endian sizes
    case wave       // an `id3 ` chunk inside a RIFF, little-endian sizes

    static func forExtension(_ ext: String) -> ID3Container? {
        switch ext.lowercased() {
        case "mp3": .bare
        case "aiff", "aif": .aiff
        case "wav", "wave": .wave
        default: nil
        }
    }
}

/// A chunk in a FORM or RIFF container. Payloads are kept whole and put back
/// untouched, so `data`, `SSND`, `bext` and anything else survive an edit intact.
struct MediaChunk: Equatable {
    var id: String
    var payload: Data
}

enum ID3Containers {
    /// The ID3v2 blob inside the file, or nil when the container carries none.
    static func extractTag(from file: Data, kind: ID3Container) throws -> Data? {
        switch kind {
        case .bare:
            guard ID3v2.hasTag(file), let tag = try ID3v2.parse(file) else { return nil }
            return file.sliceAt(0, tag.encodedByteCount)
        case .aiff, .wave:
            let (_, chunks) = try parseChunks(file, kind: kind)
            return chunks.first { $0.id.lowercased() == "id3 " }?.payload
        }
    }

    /// Rebuilds the file around a new ID3v2 blob, mirroring any legacy tag form that
    /// is already there.
    static func replaceTag(in file: Data, kind: ID3Container,
                           newTag: [UInt8], fields: TagFields) throws -> Data {
        switch kind {
        case .bare:
            return try replaceBare(in: file, newTag: newTag, fields: fields)
        case .aiff, .wave:
            return try replaceChunked(in: file, kind: kind, newTag: newTag, fields: fields)
        }
    }

    // MARK: mp3

    private static func replaceBare(in file: Data, newTag: [UInt8],
                                    fields: TagFields) throws -> Data {
        let existing = try ID3v2.parse(file)
        let audioStart = existing?.encodedByteCount ?? 0
        guard var audio = file.sliceAt(audioStart, file.count - audioStart) else {
            throw TagWriteError.malformed("ID3 tag runs past the end of the file")
        }

        // The 128-byte v1 tag at the tail is mirrored when it exists and never created.
        if ID3v1.isPresent(in: file), audio.count >= ID3v1.length {
            let split = audio.count - ID3v1.length
            guard let body = audio.sliceAt(0, split),
                  let v1 = audio.sliceAt(split, ID3v1.length) else {
                throw TagWriteError.malformed("truncated ID3v1 tag")
            }
            audio = body + ID3v1.updated(v1, with: fields)
        }

        return Data(newTag) + audio
    }

    // MARK: FORM and RIFF

    private static func replaceChunked(in file: Data, kind: ID3Container,
                                       newTag: [UInt8], fields: TagFields) throws -> Data {
        var (formType, chunks) = try parseChunks(file, kind: kind)
        let tagChunkID = kind == .aiff ? "ID3 " : "id3 "

        if let i = chunks.firstIndex(where: { $0.id.lowercased() == "id3 " }) {
            chunks[i].payload = Data(newTag)
        } else {
            chunks.append(MediaChunk(id: tagChunkID, payload: Data(newTag)))
        }

        mirrorLegacyChunks(&chunks, kind: kind, fields: fields)
        return serialiseChunks(formType: formType, chunks: chunks, kind: kind)
    }

    /// Updates the pre-ID3 metadata conventions when a file already uses them, so
    /// Finder and QuickTime stop showing a name the file no longer has. Never creates
    /// them: an absent legacy chunk is not a problem to solve.
    private static func mirrorLegacyChunks(_ chunks: inout [MediaChunk],
                                           kind: ID3Container, fields: TagFields) {
        switch kind {
        case .wave:
            guard let i = chunks.firstIndex(where: {
                $0.id == "LIST" && $0.payload.asciiAt(0, 4) == "INFO"
            }) else { return }
            chunks[i].payload = updatedInfoList(chunks[i].payload, fields: fields)
        case .aiff:
            // AIFF's own text chunks, which predate anyone putting ID3 in a FORM.
            setAIFFTextChunk(&chunks, id: "NAME", value: fields.title)
            setAIFFTextChunk(&chunks, id: "AUTH", value: fields.artist)
        case .bare:
            break
        }
    }

    private static func setAIFFTextChunk(_ chunks: inout [MediaChunk],
                                         id: String, value: String?) {
        guard let i = chunks.firstIndex(where: { $0.id == id }) else { return }
        guard let value, let latin1 = value.data(using: .isoLatin1, allowLossyConversion: true)
        else {
            chunks.remove(at: i)
            return
        }
        chunks[i].payload = latin1
    }

    /// A LIST/INFO payload is `INFO` followed by sub-chunks in the same layout as the
    /// container's own, holding null-terminated Latin-1 strings.
    private static func updatedInfoList(_ payload: Data, fields: TagFields) -> Data {
        guard payload.asciiAt(0, 4) == "INFO" else { return payload }
        var entries = (try? parseChunkList(payload, from: 4, littleEndian: true)) ?? []

        func set(_ id: String, _ value: String?) {
            let i = entries.firstIndex { $0.id == id }
            guard let value,
                  let latin1 = value.data(using: .isoLatin1, allowLossyConversion: true) else {
                if let i { entries.remove(at: i) }
                return
            }
            let text = latin1 + Data([0])
            if let i { entries[i].payload = text }
            else { entries.append(MediaChunk(id: id, payload: text)) }
        }

        set("INAM", fields.title)
        set("IART", fields.artist)
        set("IPRD", fields.album)

        var out = Data("INFO".utf8)
        for entry in entries { out += encodeChunk(entry, littleEndian: true) }
        return out
    }

    // MARK: Chunk plumbing

    private static func parseChunks(_ file: Data,
                                    kind: ID3Container) throws -> (String, [MediaChunk]) {
        let littleEndian = kind == .wave
        let expected = kind == .aiff ? "FORM" : "RIFF"
        guard file.asciiAt(0, 4) == expected else {
            throw TagWriteError.malformed("not a \(expected) container")
        }
        guard let formType = file.asciiAt(8, 4) else {
            throw TagWriteError.malformed("truncated \(expected) header")
        }
        return (formType, try parseChunkList(file, from: 12, littleEndian: littleEndian))
    }

    private static func parseChunkList(_ data: Data, from start: Int,
                                       littleEndian: Bool) throws -> [MediaChunk] {
        var chunks: [MediaChunk] = []
        var offset = start

        while offset + 8 <= data.count {
            guard let id = data.asciiAt(offset, 4) else { break }
            guard let size = littleEndian ? data.littleEndianUInt32At(offset + 4)
                                          : data.bigEndianUInt32At(offset + 4) else { break }
            guard let payload = data.sliceAt(offset + 8, Int(size)) else {
                throw TagWriteError.malformed(
                    "chunk '\(id)' claims \(size) bytes, only \(data.count - offset - 8) remain")
            }
            chunks.append(MediaChunk(id: id, payload: payload))
            offset += 8 + Int(size)
            if size % 2 == 1 { offset += 1 }    // chunks are padded to an even length
        }

        // Trailing bytes that are not a whole chunk mean the parse lost its place, and
        // rebuilding the file from here would drop them.
        guard offset >= data.count || data.sliceAt(offset, data.count - offset)?
            .allSatisfy({ $0 == 0 }) == true else {
            throw TagWriteError.malformed("\(data.count - offset) trailing bytes are not a chunk")
        }
        return chunks
    }

    private static func encodeChunk(_ chunk: MediaChunk, littleEndian: Bool) -> Data {
        var id = Array(chunk.id.utf8.prefix(4))
        while id.count < 4 { id.append(0x20) }
        let size = UInt32(chunk.payload.count)
        var out = Data(id)
        out += Data(littleEndian ? ByteWriting.littleEndianUInt32(size)
                                 : ByteWriting.bigEndianUInt32(size))
        out += chunk.payload
        if chunk.payload.count % 2 == 1 { out += Data([0]) }
        return out
    }

    private static func serialiseChunks(formType: String, chunks: [MediaChunk],
                                        kind: ID3Container) -> Data {
        let littleEndian = kind == .wave
        var body = Data(formType.utf8)
        for chunk in chunks { body += encodeChunk(chunk, littleEndian: littleEndian) }

        var out = Data((kind == .aiff ? "FORM" : "RIFF").utf8)
        out += Data(littleEndian ? ByteWriting.littleEndianUInt32(UInt32(body.count))
                                 : ByteWriting.bigEndianUInt32(UInt32(body.count)))
        return out + body
    }
}

extension ID3Containers {
    /// The chunk holding the actual samples, for checks that need to prove not one of
    /// them moved.
    static func audioPayload(_ file: Data, kind: ID3Container) -> Data? {
        guard let (_, chunks) = try? parseChunks(file, kind: kind) else { return nil }
        let wanted = kind == .aiff ? "SSND" : "data"
        return chunks.first { $0.id == wanted }?.payload
    }
}
