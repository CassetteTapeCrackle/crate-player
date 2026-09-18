import Foundation

/// One audio file on disk. Identity is its URL, which is unique per file.
public struct Track: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Filename with the extension stripped, used as the title fallback.
    public var filename: String { url.deletingPathExtension().lastPathComponent }

    /// The directory containing this file. Its tracks form the play queue.
    public var folderURL: URL { url.deletingLastPathComponent() }
}

/// A directory in the library tree. `directTrackCount` counts audio files sitting
/// immediately inside, never inside `children`, because play scope is flat.
public struct FolderNode: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let directTrackCount: Int
    public let children: [FolderNode]

    public init(url: URL, name: String, directTrackCount: Int, children: [FolderNode]) {
        self.url = url
        self.name = name
        self.directTrackCount = directTrackCount
        self.children = children
    }
}

/// Tags read from a file. Every field is optional because tags are frequently absent
/// or junk, and the display layer decides what to fall back to.
public struct TrackMetadata: Codable, Hashable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var durationSeconds: Double?
    public var hasEmbeddedArtwork: Bool

    public init(title: String? = nil, artist: String? = nil, album: String? = nil,
                durationSeconds: Double? = nil, hasEmbeddedArtwork: Bool = false) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.hasEmbeddedArtwork = hasEmbeddedArtwork
    }
}

/// Deezer's model: off stops at the end of the folder, folder restarts it, track
/// repeats the current file.
public enum LoopMode: String, CaseIterable, Codable, Sendable {
    case off, folder, track

    public var next: LoopMode {
        switch self {
        case .off: .folder
        case .folder: .track
        case .track: .off
        }
    }
}
