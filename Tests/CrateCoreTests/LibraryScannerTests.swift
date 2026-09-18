import Foundation
import Testing
@testable import CrateCore

@Test func buildsTreeWithDirectCountsOnly() throws {
    let root = try makeFixture("scan", [
        "TechNO!/Hypnotic/a.mp3",
        "TechNO!/Hypnotic/b.mp3",
        "TechNO!/Slow/c.mp3",
        "Ambient/loose.aiff",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let tree = try LibraryScanner.scan(root: root)
    #expect(tree.map(\.name) == ["Ambient", "TechNO!"])

    let ambient = tree[0]
    #expect(ambient.directTrackCount == 1)
    #expect(ambient.children.isEmpty)

    let techno = tree[1]
    // Parent holds no loose files, so its own count is zero even though its children
    // contain three tracks. Play scope is flat.
    #expect(techno.directTrackCount == 0)
    #expect(techno.children.map(\.name) == ["Hypnotic", "Slow"])
    #expect(techno.children[0].directTrackCount == 2)
}

@Test func countsIgnoreNonAudioFiles() throws {
    let root = try makeFixture("scan", ["House/cover.jpg", "House/track.mp3"])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try LibraryScanner.scan(root: root)[0].directTrackCount == 1)
}

@Test func missingRootThrows() {
    let missing = URL(fileURLWithPath: "/definitely/not/here-\(UUID().uuidString)")
    #expect(throws: (any Error).self) { try LibraryScanner.scan(root: missing) }
}
