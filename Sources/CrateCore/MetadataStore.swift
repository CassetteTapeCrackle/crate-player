import Foundation

public protocol MetadataLoading: Sendable {
    func load(_ url: URL) async -> TrackMetadata
}

public struct TrackDisplay: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String

    public init(title: String, artist: String, album: String) {
        self.title = title
        self.artist = artist
        self.album = album
    }
}

public enum ArtworkSource: Equatable, Sendable {
    case embedded(URL)
    case folderCover(URL)
    case placeholder
}

/// Reads tags through an injected loader and caches the result on disk, keyed by path
/// plus modification time plus size. Library-wide search needs every track indexed, so
/// this holds the whole collection in memory. At the scale this was built for, roughly
/// 1,700 files, that is a few hundred kilobytes.
public actor MetadataStore {
    private struct Entry: Codable {
        var metadata: TrackMetadata
        var modified: Double
        var size: Int64
    }

    private let loader: any MetadataLoading
    private let cacheURL: URL
    private var entries: [String: Entry] = [:]
    private var dirty = false

    public init(loader: any MetadataLoading, cacheURL: URL) {
        self.loader = loader
        self.cacheURL = cacheURL
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    public var loadedCount: Int { entries.count }

    public func metadata(for track: Track) async -> TrackMetadata {
        let key = track.url.path
        let stamp = Self.stamp(for: track.url)

        if let cached = entries[key],
           cached.modified == stamp.modified,
           cached.size == stamp.size {
            return cached.metadata
        }

        let fresh = await loader.load(track.url)
        entries[key] = Entry(metadata: fresh, modified: stamp.modified, size: stamp.size)
        dirty = true
        return fresh
    }

    public func save() throws {
        guard dirty else { return }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: cacheURL, options: .atomic)
        dirty = false
    }

    /// Uses FileManager rather than URL.resourceValues, which caches its results and
    /// would keep reporting a stale size after the file changed underneath us.
    private static func stamp(for url: URL) -> (modified: Double, size: Int64) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return (0, 0) }
        let modified = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return (modified, size)
    }

    // Pure helpers, deliberately not actor-isolated so views can call them directly.

    /// Tags win when present and non-blank, otherwise the filename stands in for the
    /// title and the other fields stay empty. Filenames are never parsed for an artist:
    /// a confidently wrong artist is worse than a blank one.
    public nonisolated static func display(track: Track, metadata: TrackMetadata) -> TrackDisplay {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
            else { return nil }
            return t
        }
        return TrackDisplay(
            title: clean(metadata.title) ?? track.filename,
            artist: clean(metadata.artist) ?? "",
            album: clean(metadata.album) ?? ""
        )
    }

    public nonisolated static func artworkSource(
        for track: Track,
        metadata: TrackMetadata,
        fileManager: FileManager = .default
    ) -> ArtworkSource {
        if metadata.hasEmbeddedArtwork { return .embedded(track.url) }

        for name in ["cover.jpg", "cover.jpeg", "cover.png", "folder.jpg"] {
            let candidate = track.folderURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) {
                return .folderCover(candidate)
            }
        }
        return .placeholder
    }
}
