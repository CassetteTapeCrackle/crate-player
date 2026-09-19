import Foundation
import Testing
@testable import CrateCore

// MARK: The preservation guarantee

@Test func unknownFramesSurviveATitleEditByteForByte() throws {
    let tag = TagFixtures.id3Tag(major: 3, frames: [
        ("TIT2", TagFixtures.latin1Text("Old Title")),
        ("GEOB", TagFixtures.seratoGEOB),
        ("TXXX", TagFixtures.latin1Text("SERATO_ANALYSIS")),
        ("APIC", Data([0x00, 0xFF, 0xD8, 0xFF, 0xE0, 0x10, 0x20])),
    ])
    let url = try TagFixtures.write(TagFixtures.mp3(tag: tag), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("New Title")), to: url)

    let after = try Data(contentsOf: url)
    let parsed = try #require(try ID3v2.parse(after))
    #expect(parsed.text(for: "TIT2") == "New Title")
    #expect(parsed.frames.first { $0.id == "GEOB" }?.payload == TagFixtures.seratoGEOB)
    #expect(parsed.frames.first { $0.id == "APIC" }?.payload
        == Data([0x00, 0xFF, 0xD8, 0xFF, 0xE0, 0x10, 0x20]))
    #expect(parsed.frames.map(\.id) == ["TIT2", "GEOB", "TXXX", "APIC"])
}

@Test func audioPayloadIsUntouchedByAnEdit() throws {
    let tag = TagFixtures.id3Tag(major: 3, frames: [("TIT2", TagFixtures.latin1Text("A"))])
    let url = try TagFixtures.write(TagFixtures.mp3(tag: tag), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(artist: .set("Someone")), to: url)

    let after = try Data(contentsOf: url)
    let parsed = try #require(try ID3v2.parse(after))
    #expect(after.suffix(from: parsed.encodedByteCount) == TagFixtures.mp3Audio)
}

// MARK: Versions

@Test(arguments: [UInt8(2), 3, 4])
func everyVersionRoundTrips(major: UInt8) throws {
    let ids = major == 2 ? ("TT2", "TP1", "TAL") : ("TIT2", "TPE1", "TALB")
    let tag = TagFixtures.id3Tag(major: major, frames: [
        (ids.0, TagFixtures.latin1Text("Title")),
        (ids.1, TagFixtures.latin1Text("Artist")),
        (ids.2, TagFixtures.latin1Text("Album")),
    ])
    let url = try TagFixtures.write(TagFixtures.mp3(tag: tag), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(artist: .set("Edited")), to: url)

    let fields = try #require(TagReader.read(url))
    #expect(fields.title == "Title")
    #expect(fields.artist == "Edited")
    #expect(fields.album == "Album")

    // The version must not drift: a v2.2 tag upgraded to v2.3 could not carry its
    // unknown 3-character frame identifiers across.
    let after = try #require(try ID3v2.parse(try Data(contentsOf: url)))
    #expect(after.majorVersion == major)
}

@Test func v22FramesAreNotUpgradedToV23Identifiers() throws {
    let tag = TagFixtures.id3Tag(major: 2, frames: [
        ("TT2", TagFixtures.latin1Text("Title")),
        ("PIC", Data([0x00, 0x4A, 0x50, 0x47, 0x03, 0xAB])),
    ])
    let url = try TagFixtures.write(TagFixtures.mp3(tag: tag), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("Changed")), to: url)

    let after = try #require(try ID3v2.parse(try Data(contentsOf: url)))
    #expect(after.frames.map(\.id) == ["TT2", "PIC"])
    #expect(after.frames.first { $0.id == "PIC" }?.payload == Data([0x00, 0x4A, 0x50, 0x47, 0x03, 0xAB]))
}

/// iTunes and older Lame wrote v2.4 frame sizes as plain big-endian rather than
/// syncsafe. Every other player copes, so refusing the file would be a Crate bug.
@Test func v24FramesWithNonSyncsafeSizesAreStillRead() throws {
    let long = String(repeating: "x", count: 200)   // 200 > 0x7F, so the two differ
    let tag = TagFixtures.id3Tag(major: 4, frames: [
        ("TIT2", TagFixtures.latin1Text(long)),
        ("GEOB", TagFixtures.seratoGEOB),
    ], syncsafeFrameSizes: false)
    let url = try TagFixtures.write(TagFixtures.mp3(tag: tag), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    #expect(TagReader.read(url)?.title == long)

    try TagWriter.write(TagEdit(title: .set("Short")), to: url)
    let after = try #require(try ID3v2.parse(try Data(contentsOf: url)))
    #expect(after.text(for: "TIT2") == "Short")
    #expect(after.frames.first { $0.id == "GEOB" }?.payload == TagFixtures.seratoGEOB)
}

// MARK: Unsynchronisation

@Test func aTagLevelUnsynchronisedTagIsReadAndRewrittenPlainly() throws {
    // A payload full of FF bytes is what the escaping exists for.
    let awkward = Data([0xFF, 0xE3, 0xFF, 0x00, 0xFF, 0xFB, 0x12])
    let tag = TagFixtures.id3Tag(major: 3, frames: [
        ("TIT2", TagFixtures.latin1Text("Title")),
        ("GEOB", awkward),
    ], unsynchronised: true)
    let url = try TagFixtures.write(TagFixtures.mp3(tag: tag), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    #expect(TagReader.read(url)?.title == "Title")

    try TagWriter.write(TagEdit(album: .set("Record")), to: url)

    let after = try Data(contentsOf: url)
    #expect(after.byteAt(5)! & 0x80 == 0, "the unsynchronisation flag must be cleared")
    let parsed = try #require(try ID3v2.parse(after))
    #expect(parsed.frames.first { $0.id == "GEOB" }?.payload == awkward)
    #expect(parsed.text(for: "TALB") == "Record")
}

@Test func aV24FooterIsDroppedAndTheAudioStillStartsInTheRightPlace() throws {
    let tag = TagFixtures.id3Tag(major: 4, frames: [("TIT2", TagFixtures.latin1Text("T"))],
                                 footer: true)
    let url = try TagFixtures.write(TagFixtures.mp3(tag: tag), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("U")), to: url)

    let after = try Data(contentsOf: url)
    let parsed = try #require(try ID3v2.parse(after))
    #expect(after.suffix(from: parsed.encodedByteCount) == TagFixtures.mp3Audio)
}

// MARK: Encodings

@Test(arguments: ["Plain ASCII", "Café Crème", "日本語のタイトル", "Ægir ↔ Þór"])
func everyTextEncodingRoundTrips(value: String) throws {
    let url = try TagFixtures.write(TagFixtures.mp3(tag: nil), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set(value)), to: url)
    #expect(TagReader.read(url)?.title == value)
}

@Test func utf16InputIsReadBack() throws {
    let tag = TagFixtures.id3Tag(major: 3, frames: [("TIT2", TagFixtures.utf16Text("Ünïcøde"))])
    let url = try TagFixtures.write(TagFixtures.mp3(tag: tag), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    #expect(TagReader.read(url)?.title == "Ünïcøde")
}

/// Some titles in this collection are built entirely from bidi and zero-width marks.
/// They draw nothing, but deciding they are illegible belongs to the display layer,
/// not to the tag codec, which must hand them back exactly as it found them.
@Test func invisibleButNonEmptyTitlesSurvive() throws {
    let invisible = "\u{200B}\u{200E}\u{FEFF}\u{200F}"
    let url = try TagFixtures.write(TagFixtures.mp3(tag: nil), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set(invisible)), to: url)
    #expect(TagReader.read(url)?.title == invisible)
    #expect(MetadataStore.visible(invisible) == nil, "still not something to display")
}

// MARK: Creating, clearing and growing

@Test func aFileWithNoTagGetsAFreshV23One() throws {
    let url = try TagFixtures.write(TagFixtures.mp3(tag: nil), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("First"), artist: .set("Someone")), to: url)

    let after = try Data(contentsOf: url)
    let parsed = try #require(try ID3v2.parse(after))
    #expect(parsed.majorVersion == 3)
    #expect(parsed.fields == TagFields(title: "First", artist: "Someone", album: nil))
    #expect(after.suffix(from: parsed.encodedByteCount) == TagFixtures.mp3Audio)
}

@Test func clearingAFieldRemovesTheFrameRatherThanWritingAnEmptyOne() throws {
    let tag = TagFixtures.id3Tag(major: 3, frames: [
        ("TIT2", TagFixtures.latin1Text("Title")),
        ("TPE1", TagFixtures.latin1Text("Artist")),
    ])
    let url = try TagFixtures.write(TagFixtures.mp3(tag: tag), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(artist: .cleared), to: url)

    let parsed = try #require(try ID3v2.parse(try Data(contentsOf: url)))
    #expect(!parsed.frames.contains { $0.id == "TPE1" })
    #expect(parsed.text(for: "TIT2") == "Title")
}

@Test func writingWhitespaceCountsAsClearing() throws {
    let tag = TagFixtures.id3Tag(major: 3, frames: [("TPE1", TagFixtures.latin1Text("Artist"))])
    let url = try TagFixtures.write(TagFixtures.mp3(tag: tag), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(artist: .set("   ")), to: url)
    #expect(TagReader.read(url)?.artist == nil)
}

@Test func unchangedFieldsAreLeftExactlyAsTheyWere() throws {
    let tag = TagFixtures.id3Tag(major: 3, frames: [
        ("TIT2", TagFixtures.latin1Text("Keep me")),
        ("TALB", TagFixtures.latin1Text("Keep me too")),
    ])
    let url = try TagFixtures.write(TagFixtures.mp3(tag: tag), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(artist: .set("Only this")), to: url)

    let fields = try #require(TagReader.read(url))
    #expect(fields == TagFields(title: "Keep me", artist: "Only this", album: "Keep me too"))
}

@Test func aTagTooSmallForTheNewFramesGrowsAndKeepsTheAudioIntact() throws {
    let tag = TagFixtures.id3Tag(major: 3, frames: [("TIT2", TagFixtures.latin1Text("a"))],
                                 padding: 0)
    let url = try TagFixtures.write(TagFixtures.mp3(tag: tag), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    let long = String(repeating: "long title ", count: 40)
    try TagWriter.write(TagEdit(title: .set(long)), to: url)

    let after = try Data(contentsOf: url)
    let parsed = try #require(try ID3v2.parse(after))
    #expect(parsed.text(for: "TIT2") == long)
    #expect(after.suffix(from: parsed.encodedByteCount) == TagFixtures.mp3Audio)
}

// MARK: ID3v1

@Test func anExistingID3v1TagIsMirroredAndItsOtherFieldsKept() throws {
    let tag = TagFixtures.id3Tag(major: 3, frames: [("TIT2", TagFixtures.latin1Text("Old"))])
    let file = TagFixtures.mp3(tag: tag, v1: TagFixtures.id3v1Tag)
    let url = try TagFixtures.write(file, as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("New"), artist: .set("Band")), to: url)

    let after = try Data(contentsOf: url)
    let v1 = try #require(after.sliceAt(after.count - 128, 128))
    #expect(v1.asciiAt(0, 3) == "TAG")
    #expect(v1.asciiAt(3, 3) == "New")
    #expect(v1.asciiAt(33, 4) == "Band")
    #expect(v1.asciiAt(93, 4) == "1999", "year is not ours to touch")
    #expect(v1.byteAt(127) == 17, "genre is not ours to touch")
}

@Test func noID3v1TagIsInventedForAFileWithoutOne() throws {
    let url = try TagFixtures.write(TagFixtures.mp3(tag: nil), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("T")), to: url)

    let after = try Data(contentsOf: url)
    #expect(after.sliceAt(after.count - 128, 3).map { $0.asciiAt(0, 3) } != "TAG")
}

// MARK: Refusals

@Test func anUnsupportedContainerIsRefusedRatherThanSilentlyIgnored() throws {
    let url = try TagFixtures.write(Data([0x00, 0x01, 0x02]), as: "a.m4a")
    defer { TagFixtures.cleanUp(url) }

    #expect(!TagWriter.canWrite(url))
    #expect(throws: TagWriteError.unsupportedFormat("m4a")) {
        try TagWriter.write(TagEdit(title: .set("T")), to: url)
    }
}

@Test func aTagWhoseFramesDoNotAddUpIsRefusedAndTheFileIsLeftAlone() throws {
    // A frame claiming far more bytes than the tag holds.
    var bytes = Array("ID3".utf8) + [3, 0, 0] + ByteWriting.syncsafeUInt32(20)
    bytes += Array("TIT2".utf8) + ByteWriting.bigEndianUInt32(9_000) + [0, 0]
    bytes += [UInt8](repeating: 0, count: 10)
    let original = Data(bytes) + TagFixtures.mp3Audio
    let url = try TagFixtures.write(original, as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    #expect(throws: (any Error).self) {
        try TagWriter.write(TagEdit(title: .set("T")), to: url)
    }
    #expect(try Data(contentsOf: url) == original, "a refused write must change nothing")
}

@Test func anEditThatChangesNothingDoesNotRewriteTheFile() throws {
    let tag = TagFixtures.id3Tag(major: 3, frames: [("TIT2", TagFixtures.latin1Text("T"))])
    let original = TagFixtures.mp3(tag: tag)
    let url = try TagFixtures.write(original, as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(), to: url)
    #expect(try Data(contentsOf: url) == original)
}
