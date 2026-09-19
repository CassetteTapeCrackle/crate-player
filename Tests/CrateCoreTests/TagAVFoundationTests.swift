import AVFoundation
import Foundation
import Testing
@testable import CrateCore

/// Real, decodable PCM files, built here rather than checked in as binaries.
///
/// The synthetic fixtures elsewhere prove the byte surgery is right. These prove
/// AVFoundation still accepts the result, which is the part no amount of
/// self-consistency can establish.
private enum PCMFixtures {
    static let sampleRate = 44_100
    static let frames = 2_205          // 50ms, enough for a measurable duration

    private static var samples: Data {
        var out = Data(capacity: frames * 2)
        for i in 0 ..< frames {
            let value = Int16(3_000 * sin(Double(i) * 0.05))
            out += Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)])
        }
        return out
    }

    static func wave() -> Data {
        var fmt = Data()
        fmt += Data(ByteWriting.littleEndianUInt32(1 | (1 << 16)))          // PCM, mono
        fmt += Data(ByteWriting.littleEndianUInt32(UInt32(sampleRate)))
        fmt += Data(ByteWriting.littleEndianUInt32(UInt32(sampleRate * 2))) // byte rate
        fmt += Data(ByteWriting.littleEndianUInt32(2 | (16 << 16)))         // align, bits
        return TagFixtures.wave([("fmt ", fmt), ("data", samples)])
    }

    static func aiff() -> Data {
        var comm = Data()
        comm += Data([0x00, 0x01])                                    // one channel
        comm += Data(ByteWriting.bigEndianUInt32(UInt32(frames)))
        comm += Data([0x00, 0x10])                                    // 16 bits
        // 44100 as an 80-bit IEEE extended float, which is how AIFF stores a rate.
        comm += Data([0x40, 0x0E, 0xAC, 0x44, 0, 0, 0, 0, 0, 0])
        let ssnd = Data(ByteWriting.bigEndianUInt32(0))
            + Data(ByteWriting.bigEndianUInt32(0)) + samples
        return TagFixtures.aiff([("COMM", comm), ("SSND", ssnd)])
    }
}

private func avTitle(_ url: URL) async -> String? {
    let asset = AVURLAsset(url: url)
    guard let items = try? await asset.load(.commonMetadata) else { return nil }
    for item in items where item.commonKey == .commonKeyTitle {
        if let value = try? await item.load(.stringValue) { return value }
    }
    return nil
}

@Test func aTaggedWaveStaysDecodableAndCrateReadsItsTitle() async throws {
    let url = try TagFixtures.write(PCMFixtures.wave(), as: "tone.wav")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("Tone Test"), artist: .set("Crate")), to: url)

    // AVFoundation must still open the file and measure it. This is the assertion that
    // catches chunk surgery that produced a structurally broken container.
    let meta = await TagMetadataLoader().load(url)
    let duration = try #require(meta.durationSeconds)
    #expect(abs(duration - 0.05) < 0.01, "AVFoundation must still decode the audio")

    // And the composition reports our tag, whichever chunk Apple's parser favours.
    #expect(meta.title == "Tone Test")
    #expect(meta.artist == "Crate")

    // Measured, not assumed: Apple's WAVE parser does surface the `id3 ` chunk. Crate
    // does not depend on that staying true, but if it ever stops being true this test
    // says so rather than leaving it to be rediscovered against a real library.
    #expect(await avTitle(url) == "Tone Test")
}

@Test func aTaggedAIFFStaysDecodableAndCrateReadsItsTitle() async throws {
    let url = try TagFixtures.write(PCMFixtures.aiff(), as: "tone.aiff")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("Form Test")), to: url)

    let meta = await TagMetadataLoader().load(url)
    let duration = try #require(meta.durationSeconds)
    #expect(abs(duration - 0.05) < 0.01, "AVFoundation must still decode the audio")
    #expect(meta.title == "Form Test")

    #expect(await avTitle(url) == "Form Test")
}

/// Editing must not disturb a single audio sample, which is the promise that lets
/// someone run this over a collection they cannot replace.
@Test func editingAWaveLeavesEverySampleWhereItWas() throws {
    let original = PCMFixtures.wave()
    let url = try TagFixtures.write(original, as: "tone.wav")
    defer { TagFixtures.cleanUp(url) }

    try TagWriter.write(TagEdit(title: .set("One")), to: url)
    try TagWriter.write(TagEdit(artist: .set("Two")), to: url)
    try TagWriter.write(TagEdit(title: .cleared), to: url)

    let before = try #require(ID3Containers.audioPayload(original, kind: .wave))
    let after = try #require(ID3Containers.audioPayload(try Data(contentsOf: url), kind: .wave))
    #expect(before == after)
}

/// A format with no writer must still read through AVFoundation untouched, so
/// deferring m4a costs nothing on the display side.
@Test func anUnwritableFormatStillReadsThroughAVFoundation() async throws {
    let url = try TagFixtures.write(Data([0x00, 0x01]), as: "x.m4a")
    defer { TagFixtures.cleanUp(url) }

    #expect(TagReader.read(url) == nil)
    let meta = await TagMetadataLoader().load(url)
    #expect(meta.title == nil)     // nothing to read, but nothing crashed either
}
