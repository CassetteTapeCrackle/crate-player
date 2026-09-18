import Foundation
import Testing
@testable import CrateCore

/// Builds a throwaway directory tree so tests touch real files rather than mocks.
func makeFixture(_ prefix: String, _ files: [String]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("crate-\(prefix)-\(UUID().uuidString)")
    for f in files {
        let url = root.appendingPathComponent(f)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
    return root
}

@Test func recognisesEveryFormatInTheCollection() {
    for ext in ["mp3", "MP3", "wav", "aiff", "flac", "m4a", "aac", "alac"] {
        #expect(AudioFiles.isAudio(URL(fileURLWithPath: "/x/song.\(ext)")))
    }
}

@Test func rejectsNonAudioSittingAlongsideTracks() {
    for name in ["cover.jpg", "notes.pdf", "bundle.zip", "link.textclipping"] {
        #expect(!AudioFiles.isAudio(URL(fileURLWithPath: "/x/\(name)")))
    }
}

@Test func listsOnlyDirectChildrenInNaturalOrder() throws {
    let root = try makeFixture("audio", [
        "Hypnotic/track 10.mp3",
        "Hypnotic/track 2.mp3",
        "Hypnotic/cover.jpg",
        "Hypnotic/Deeper/nested.mp3",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let tracks = try AudioFiles.tracks(in: root.appendingPathComponent("Hypnotic"))
    #expect(tracks.map(\.filename) == ["track 2", "track 10"])
}

@Test func emptyFolderYieldsNoTracks() throws {
    let root = try makeFixture("audio", ["Empty/placeholder.jpg"])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try AudioFiles.tracks(in: root.appendingPathComponent("Empty")).isEmpty)
}
