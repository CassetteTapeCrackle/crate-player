import Foundation
import Testing
@testable import CrateCore

// MARK: AIFF

@Test func anAIFFKeepsItsSoundChunkAndGainsAnID3Chunk() throws {
    let file = TagFixtures.aiff([
        ("COMM", Data([UInt8](repeating: 0x01, count: 18))),
        ("SSND", TagFixtures.sampleAudioChunk),
    ])
    let url = try TagFixtures.write(file, as: "a.aiff")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("Deep Cut"), artist: .set("Someone")), to: url)

    #expect(TagReader.read(url) == TagFields(title: "Deep Cut", artist: "Someone"))

    let after = try Data(contentsOf: url)
    #expect(after.asciiAt(0, 4) == "FORM")
    #expect(after.asciiAt(8, 4) == "AIFF")
    #expect(after.bigEndianUInt32At(4) == UInt32(after.count - 8), "FORM size must be fixed up")
    #expect(after.range(of: TagFixtures.sampleAudioChunk) != nil, "audio must survive verbatim")
}

@Test func anExistingAIFFID3ChunkIsReplacedNotDuplicated() throws {
    let tag = TagFixtures.id3Tag(major: 3, frames: [
        ("TIT2", TagFixtures.latin1Text("Old")),
        ("GEOB", TagFixtures.seratoGEOB),
    ])
    let file = TagFixtures.aiff([
        ("SSND", TagFixtures.sampleAudioChunk),
        ("ID3 ", tag),
    ])
    let url = try TagFixtures.write(file, as: "a.aiff")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("New")), to: url)

    let blob = try #require(try ID3Containers.extractTag(
        from: try Data(contentsOf: url), kind: .aiff))
    let parsed = try #require(try ID3v2.parse(blob))
    #expect(parsed.text(for: "TIT2") == "New")
    #expect(parsed.frames.first { $0.id == "GEOB" }?.payload == TagFixtures.seratoGEOB)
}

/// AIFF's own text chunks predate anyone putting ID3 in a FORM. Mirrored when present
/// so other tools stop showing a name the file no longer has.
@Test func aiffNameAndAuthChunksAreMirroredWhenPresent() throws {
    let file = TagFixtures.aiff([
        ("NAME", Data("Old Name".utf8)),
        ("AUTH", Data("Old Author".utf8)),
        ("SSND", TagFixtures.sampleAudioChunk),
    ])
    let url = try TagFixtures.write(file, as: "a.aiff")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("Fresh"), artist: .set("Player")), to: url)

    let after = try Data(contentsOf: url)
    #expect(after.range(of: Data("Fresh".utf8)) != nil)
    #expect(after.range(of: Data("Player".utf8)) != nil)
    #expect(after.range(of: Data("Old Name".utf8)) == nil)
}

@Test func aiffTextChunksAreNotInventedWhenAbsent() throws {
    let file = TagFixtures.aiff([("SSND", TagFixtures.sampleAudioChunk)])
    let url = try TagFixtures.write(file, as: "a.aiff")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("Fresh")), to: url)

    let after = try Data(contentsOf: url)
    #expect(after.range(of: Data("NAME".utf8)) == nil)
}

// MARK: WAVE

@Test func aWaveGetsAnId3ChunkAndKeepsItsDataChunk() throws {
    let file = TagFixtures.wave([
        ("fmt ", Data([UInt8](repeating: 0x02, count: 16))),
        ("data", TagFixtures.sampleAudioChunk),
    ])
    let url = try TagFixtures.write(file, as: "a.wav")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("Rolling"), album: .set("Dubs")), to: url)

    #expect(TagReader.read(url) == TagFields(title: "Rolling", album: "Dubs"))

    let after = try Data(contentsOf: url)
    #expect(after.asciiAt(0, 4) == "RIFF")
    #expect(after.littleEndianUInt32At(4) == UInt32(after.count - 8))
    #expect(after.range(of: TagFixtures.sampleAudioChunk) != nil)
}

/// The reason Crate reads with its own parser: whichever chunk AVFoundation prefers,
/// the answer Crate displays comes from the one Crate wrote.
@Test func aWaveCarryingBothConventionsReportsTheId3Chunk() throws {
    let tag = TagFixtures.id3Tag(major: 3, frames: [("TIT2", TagFixtures.latin1Text("From ID3"))])
    let file = TagFixtures.wave([
        ("fmt ", Data([UInt8](repeating: 0x02, count: 16))),
        ("LIST", TagFixtures.infoList([("INAM", "From INFO")])),
        ("id3 ", tag),
        ("data", TagFixtures.sampleAudioChunk),
    ])
    let url = try TagFixtures.write(file, as: "a.wav")
    defer { TagFixtures.cleanUp(url) }

    #expect(TagReader.read(url)?.title == "From ID3")
}

@Test func anExistingInfoListIsMirroredSoItCannotContradictTheTag() throws {
    let file = TagFixtures.wave([
        ("LIST", TagFixtures.infoList([("INAM", "Stale"), ("IART", "Stale Artist")])),
        ("data", TagFixtures.sampleAudioChunk),
    ])
    let url = try TagFixtures.write(file, as: "a.wav")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("Correct")), to: url)

    let after = try Data(contentsOf: url)
    #expect(after.range(of: Data("Correct".utf8)) != nil)
    #expect(after.range(of: Data("Stale".utf8)) == nil)
    #expect(after.range(of: Data("Stale Artist".utf8)) == nil,
            "artist is absent from the tag, so INFO must not keep claiming one")
}

@Test func noInfoListIsInventedForAWaveWithoutOne() throws {
    let file = TagFixtures.wave([("data", TagFixtures.sampleAudioChunk)])
    let url = try TagFixtures.write(file, as: "a.wav")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("T")), to: url)
    #expect(try Data(contentsOf: url).range(of: Data("INFO".utf8)) == nil)
}

@Test func broadcastWaveExtensionSurvivesAnEdit() throws {
    let bext = Data([UInt8](repeating: 0x7E, count: 602))
    let file = TagFixtures.wave([
        ("bext", bext),
        ("data", TagFixtures.sampleAudioChunk),
    ])
    let url = try TagFixtures.write(file, as: "a.wav")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("T")), to: url)
    #expect(try Data(contentsOf: url).range(of: bext) != nil)
}

@Test func anOddLengthChunkKeepsItsPaddingByteAndTheFileStaysParseable() throws {
    let odd = Data([UInt8](repeating: 0x33, count: 15))
    let file = TagFixtures.wave([
        ("junk", odd),
        ("data", TagFixtures.sampleAudioChunk),
    ])
    let url = try TagFixtures.write(file, as: "a.wav")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("T")), to: url)

    let after = try Data(contentsOf: url)
    #expect(after.range(of: odd) != nil)
    #expect(TagReader.read(url)?.title == "T")
}

// MARK: FLAC

@Test func flacKeepsEveryOtherMetadataBlockAndItsAudio() throws {
    let file = TagFixtures.flac(blocks: [
        (0, TagFixtures.streamInfo),
        (4, TagFixtures.vorbisBlock(vendor: "reference libFLAC", [("TITLE", "Old"),
                                                                  ("BPM", "128")])),
        (6, TagFixtures.flacPicture),
    ])
    let url = try TagFixtures.write(file, as: "a.flac")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("New"), artist: .set("Someone")), to: url)

    let after = try Data(contentsOf: url)
    #expect(after.asciiAt(0, 4) == "fLaC")
    #expect(after.range(of: TagFixtures.streamInfo) != nil)
    #expect(after.range(of: TagFixtures.flacPicture) != nil, "artwork block must survive")
    #expect(after.range(of: TagFixtures.flacAudio) != nil)
    #expect(after.range(of: Data("BPM=128".utf8)) != nil, "unknown comments must survive")

    #expect(TagReader.read(url) == TagFields(title: "New", artist: "Someone"))
}

@Test func flacWithoutACommentBlockGainsOneAfterStreamInfo() throws {
    let file = TagFixtures.flac(blocks: [
        (0, TagFixtures.streamInfo),
        (1, Data([UInt8](repeating: 0, count: 64))),
    ])
    let url = try TagFixtures.write(file, as: "a.flac")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("Fresh")), to: url)

    #expect(TagReader.read(url)?.title == "Fresh")
    #expect(try Data(contentsOf: url).range(of: TagFixtures.flacAudio) != nil)
}

@Test func flacCommentKeysAreMatchedWithoutRegardToCase() throws {
    let file = TagFixtures.flac(blocks: [
        (0, TagFixtures.streamInfo),
        (4, TagFixtures.vorbisBlock(vendor: "x", [("Title", "Mixed Case"),
                                                  ("artist", "lower")])),
    ])
    let url = try TagFixtures.write(file, as: "a.flac")
    defer { TagFixtures.cleanUp(url) }

    let fields = try #require(TagReader.read(url))
    #expect(fields.title == "Mixed Case")
    #expect(fields.artist == "lower")
}

/// Not part of the FLAC format, but taggers do it, and a stale prepended ID3 that
/// contradicts the real tag is exactly the phantom bug this rule exists to prevent.
@Test func anID3TagPrependedToAFlacIsMirrored() throws {
    let id3 = TagFixtures.id3Tag(major: 3, frames: [("TIT2", TagFixtures.latin1Text("Stale"))])
    let file = TagFixtures.flac(blocks: [
        (0, TagFixtures.streamInfo),
        (4, TagFixtures.vorbisBlock(vendor: "x", [("TITLE", "Stale")])),
    ], leadingID3: id3)
    let url = try TagFixtures.write(file, as: "a.flac")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("Correct")), to: url)

    let after = try Data(contentsOf: url)
    let leading = try #require(try ID3v2.parse(after))
    #expect(leading.text(for: "TIT2") == "Correct")
    #expect(TagReader.read(url)?.title == "Correct")
}

// MARK: Editing repeatedly

@Test func repeatedEditsDoNotGrowTheFileWithoutBound() throws {
    let tag = TagFixtures.id3Tag(major: 3, frames: [("TIT2", TagFixtures.latin1Text("One"))])
    let url = try TagFixtures.write(TagFixtures.mp3(tag: tag), as: "a.mp3")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("Two")), to: url)
    let first = try Data(contentsOf: url).count
    for name in ["Three", "Four", "Five"] {
        try TagWriter.write(TagEdit(title: .set(name)), to: url)
    }
    #expect(try Data(contentsOf: url).count == first)
}
