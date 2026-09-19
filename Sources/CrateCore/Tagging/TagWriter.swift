import Foundation

/// Which backend, if any, handles a given file.
enum TagBackend {
    case id3(ID3Container)
    case flac

    /// m4a, aac, alac and caf deliberately return nil. MPEG-4 metadata lives in
    /// `moov/udta/meta/ilst` atoms and shares no code with any of this.
    static func forExtension(_ ext: String) -> TagBackend? {
        if ext.lowercased() == "flac" { return .flac }
        if let container = ID3Container.forExtension(ext) { return .id3(container) }
        return nil
    }
}

/// Writes title, artist and album into an audio file, leaving every other byte where
/// it was.
public enum TagWriter {
    public static func canWrite(_ url: URL) -> Bool {
        TagBackend.forExtension(url.pathExtension) != nil
    }

    public static func write(_ edit: TagEdit, to url: URL) throws {
        guard let backend = TagBackend.forExtension(url.pathExtension) else {
            throw TagWriteError.unsupportedFormat(url.pathExtension)
        }
        guard !edit.touchesNothing else { return }

        let manager = FileManager.default
        guard manager.isWritableFile(atPath: url.path),
              manager.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
            throw TagWriteError.notWritable
        }

        // Mapped rather than copied: only the pages holding the tag are ever faulted
        // in, which matters when the indexer walks 1,700 files and when one of them is
        // a 400MB wav.
        let file: Data
        do {
            file = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw TagWriteError.io(error.localizedDescription)
        }

        let rewritten: Data
        switch backend {
        case .flac:
            rewritten = try FLACTagging.write(edit, into: file)
        case .id3(let container):
            rewritten = try rewriteID3(edit, in: file, container: container)
        }

        try replaceAtomically(url, with: rewritten)
    }

    private static func rewriteID3(_ edit: TagEdit, in file: Data,
                                   container: ID3Container) throws -> Data {
        let existing = try ID3Containers.extractTag(from: file, kind: container)

        // A file with no tag gets a fresh v2.3 one. v2.3 rather than v2.4 because it is
        // the version every player in the world reads without argument.
        var tag = try existing.flatMap { try ID3v2.parse($0) }
            ?? ID3Tag(majorVersion: 3, revision: 0, frames: [], encodedByteCount: 0)

        tag.apply(edit)
        let serialised = ID3v2.serialise(
            tag, preferredByteCount: existing.map { $0.count } ?? nil)

        return try ID3Containers.replaceTag(in: file, kind: container,
                                            newTag: serialised, fields: tag.fields)
    }

    /// Writes beside the original and swaps, so a crash mid-write leaves the old file
    /// intact rather than a half-written tag. `replaceItemAt` carries the creation
    /// date, permissions and Finder metadata across.
    private static func replaceAtomically(_ url: URL, with contents: Data) throws {
        let manager = FileManager.default
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".crate-tag-\(UUID().uuidString).tmp")
        do {
            try contents.write(to: temp, options: .atomic)
            _ = try manager.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? manager.removeItem(at: temp)
            throw TagWriteError.io(error.localizedDescription)
        }
    }
}
