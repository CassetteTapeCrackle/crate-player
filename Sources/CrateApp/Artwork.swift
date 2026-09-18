import AppKit
import CrateCore

/// Resolves the artwork precedence from the spec: embedded tag, then a cover file
/// sitting in the folder, then nothing.
func loadArtwork(_ source: ArtworkSource) async -> NSImage? {
    switch source {
    case .embedded(let url):
        guard let data = await AVMetadataLoader.artworkData(for: url) else { return nil }
        return NSImage(data: data)
    case .folderCover(let url):
        return NSImage(contentsOf: url)
    case .placeholder:
        return nil
    }
}
