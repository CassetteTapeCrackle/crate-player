import AppKit
import CrateCore

/// Resolves the artwork precedence from the spec: embedded tag, then a cover file
/// sitting in the folder, then nothing.
///
/// Main-actor isolated on purpose. NSImage is not Sendable, so returning one from a
/// nonisolated function to a main-actor caller is a concurrency violation that older
/// Swift 6 toolchains reject outright. Only Data crosses the await inside.
@MainActor
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
