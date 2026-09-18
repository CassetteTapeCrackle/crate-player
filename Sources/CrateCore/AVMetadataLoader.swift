import AVFoundation
import Foundation

/// Reads tags and artwork presence through AVFoundation, which handles ID3, iTunes
/// and QuickTime metadata across every format in the collection.
public struct AVMetadataLoader: MetadataLoading {
    public init() {}

    public func load(_ url: URL) async -> TrackMetadata {
        let asset = AVURLAsset(url: url)
        var result = TrackMetadata()

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 { result.durationSeconds = seconds }
        }

        guard let items = try? await asset.load(.commonMetadata) else { return result }

        for item in items {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                result.title = try? await item.load(.stringValue)
            case .commonKeyArtist, .commonKeyAuthor:
                if result.artist == nil { result.artist = try? await item.load(.stringValue) }
            case .commonKeyAlbumName:
                result.album = try? await item.load(.stringValue)
            case .commonKeyArtwork:
                if (try? await item.load(.dataValue)) != nil { result.hasEmbeddedArtwork = true }
            default:
                continue
            }
        }
        return result
    }

    /// Full artwork bytes, loaded separately so the index stays small.
    public static func artworkData(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }
}
