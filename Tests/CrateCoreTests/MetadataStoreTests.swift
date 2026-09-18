import Foundation
import Testing
@testable import CrateCore

private actor CountingLoader: MetadataLoading {
    private var calls = 0
    private let result: TrackMetadata
    init(result: TrackMetadata) { self.result = result }
    func load(_ url: URL) async -> TrackMetadata { calls += 1; return result }
    func callCount() -> Int { calls }
}

private func tempFile(_ name: String) throws -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("crate-meta-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data("x".utf8).write(to: url)
    return url
}

@Test func secondLookupComesFromCacheNotTheLoader() async throws {
    let file = try tempFile("a.mp3")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let loader = CountingLoader(result: TrackMetadata(title: "T", artist: "A"))
    let store = MetadataStore(loader: loader, cacheURL: file.deletingLastPathComponent()
        .appendingPathComponent("cache.json"))

    let track = Track(url: file)
    _ = await store.metadata(for: track)
    _ = await store.metadata(for: track)

    #expect(await loader.callCount() == 1)
}

@Test func touchingTheFileInvalidatesItsCacheEntry() async throws {
    let file = try tempFile("b.mp3")
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    let loader = CountingLoader(result: TrackMetadata(title: "T"))
    let store = MetadataStore(loader: loader, cacheURL: file.deletingLastPathComponent()
        .appendingPathComponent("cache.json"))
    let track = Track(url: file)
    _ = await store.metadata(for: track)

    try Data("changed content, different size".utf8).write(to: file)
    _ = await store.metadata(for: track)

    #expect(await loader.callCount() == 2)
}

@Test func titleFallsBackToFilenameWhenTagIsMissing() {
    let track = Track(url: URL(fileURLWithPath: "/m/Cult - High Pressure.mp3"))
    let d = MetadataStore.display(track: track, metadata: TrackMetadata())
    #expect(d.title == "Cult - High Pressure")
    #expect(d.artist == "")
    #expect(d.album == "")
}

@Test func tagsWinOverFilenameWhenPresent() {
    let track = Track(url: URL(fileURLWithPath: "/m/whatever.mp3"))
    let meta = TrackMetadata(title: "Thrix", artist: "Stef Mendesidis", album: "Micht EP")
    let d = MetadataStore.display(track: track, metadata: meta)
    #expect(d.title == "Thrix")
    #expect(d.artist == "Stef Mendesidis")
}

@Test func blankTagsAreTreatedAsMissing() {
    let track = Track(url: URL(fileURLWithPath: "/m/Real Name.mp3"))
    let d = MetadataStore.display(track: track, metadata: TrackMetadata(title: "   "))
    #expect(d.title == "Real Name")
}

@Test func artworkPrefersEmbeddedThenFolderCoverThenPlaceholder() throws {
    let file = try tempFile("c.mp3")
    let folder = file.deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: folder) }
    let track = Track(url: file)

    #expect(MetadataStore.artworkSource(
        for: track, metadata: TrackMetadata(hasEmbeddedArtwork: true)) == .embedded(file))

    #expect(MetadataStore.artworkSource(
        for: track, metadata: TrackMetadata(hasEmbeddedArtwork: false)) == .placeholder)

    let cover = folder.appendingPathComponent("cover.jpg")
    try Data("img".utf8).write(to: cover)
    #expect(MetadataStore.artworkSource(
        for: track, metadata: TrackMetadata(hasEmbeddedArtwork: false)) == .folderCover(cover))
}
