// Regression guard for the tag writer destroying data it does not understand.
//
// This library carries Serato cue points and beatgrids in ID3 GEOB frames sitting
// right beside the title frame. A writer that rebuilds a tag instead of splicing it
// wipes them, and the damage is invisible until someone loads the track in Serato.
//
// Deliberately different from the unit suite: that verifies through the parser, so a
// parser and writer wrong in matching ways would still agree with each other. This
// searches the raw bytes on disk for payloads that must have survived untouched, and
// checks the audio region separately.
//
// Run: ./Tools/check-tag-preservation.sh
import Foundation
import CrateCore

var failures: [String] = []

@MainActor
func check(_ name: String, _ condition: Bool) {
    if condition {
        print("  ok    \(name)")
    } else {
        print("  FAIL  \(name)")
        failures.append(name)
    }
}

// Payloads no part of the writer understands. Each is distinctive enough to find by
// byte search and contains 0xFF runs, which is what unsynchronisation mangles.
let seratoMarkers = Data([0x53, 0x65, 0x72, 0x61, 0x74, 0x6F, 0x20, 0x4D, 0x61, 0x72,
                          0x6B, 0x65, 0x72, 0x73, 0x32, 0x00, 0xFF, 0xE0, 0xDE, 0xAD,
                          0xBE, 0xEF, 0xFF, 0x00, 0xFB, 0x11])
let seratoBeatGrid = Data([0x53, 0x65, 0x72, 0x61, 0x74, 0x6F, 0x20, 0x42, 0x65, 0x61,
                           0x74, 0x47, 0x72, 0x69, 0x64, 0x00, 0xFF, 0xFB, 0x7A, 0x2C])
let artwork = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0xFF, 0xD9])
let audio = Data([0xFF, 0xE3, 0x18, 0xC4] + (0..<256).map { UInt8($0 % 251) })

func syncsafe(_ v: UInt32) -> [UInt8] {
    [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
}
func beUInt32(_ v: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16),
     UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
}
func leUInt32(_ v: UInt32) -> [UInt8] {
    [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
     UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
}

func id3Tag() -> Data {
    var block: [UInt8] = []
    for (id, payload) in [("TIT2", Data([0]) + Data("Original".utf8)),
                          ("GEOB", seratoMarkers),
                          ("GEOB", seratoBeatGrid),
                          ("APIC", artwork)] {
        block += Array(id.utf8) + beUInt32(UInt32(payload.count)) + [0, 0] + [UInt8](payload)
    }
    block += [UInt8](repeating: 0, count: 32)
    return Data(Array("ID3".utf8) + [3, 0, 0] + syncsafe(UInt32(block.count)) + block)
}

func chunk(_ id: String, _ payload: Data, littleEndian: Bool) -> Data {
    var out = Data(id.utf8)
    out += Data(littleEndian ? leUInt32(UInt32(payload.count)) : beUInt32(UInt32(payload.count)))
    out += payload
    if payload.count % 2 == 1 { out += Data([0]) }
    return out
}

let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("crate-tag-guard-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }

/// Writes a file, edits it, and demands the unknown payloads and the audio come back
/// unchanged at the byte level.
@MainActor
func exercise(_ name: String, contents: Data, mustSurvive: [(String, Data)]) {
    print("\(name):")
    let url = dir.appendingPathComponent(name)
    do {
        try contents.write(to: url)
        try TagWriter.write(
            TagEdit(title: .set("Rewritten"), artist: .set("Someone Else")), to: url)
    } catch {
        check("\(name) writes without error", false)
        return
    }

    guard let after = try? Data(contentsOf: url) else {
        check("\(name) is readable after the write", false)
        return
    }

    for (label, payload) in mustSurvive {
        check("\(name): \(label) survives byte for byte", after.range(of: payload) != nil)
    }
    check("\(name): the new title is present", after.range(of: Data("Rewritten".utf8)) != nil)
    check("\(name): the old title is gone", after.range(of: Data("Original".utf8)) == nil)

    guard let fields = TagReader.read(url) else {
        check("\(name) reads back", false)
        return
    }
    check("\(name): title reads back", fields.title == "Rewritten")
    check("\(name): artist reads back", fields.artist == "Someone Else")
}

let unknownID3: [(String, Data)] = [
    ("Serato Markers", seratoMarkers),
    ("Serato BeatGrid", seratoBeatGrid),
    ("embedded artwork", artwork),
    ("audio payload", audio),
]

exercise("guard.mp3", contents: id3Tag() + audio, mustSurvive: unknownID3)

exercise("guard.aiff",
         contents: {
             var body = Data("AIFF".utf8)
             body += chunk("ID3 ", id3Tag(), littleEndian: false)
             body += chunk("SSND", audio, littleEndian: false)
             return Data("FORM".utf8) + Data(beUInt32(UInt32(body.count))) + body
         }(),
         mustSurvive: unknownID3)

exercise("guard.wav",
         contents: {
             var body = Data("WAVE".utf8)
             body += chunk("bext", Data([UInt8](repeating: 0x7E, count: 60)), littleEndian: true)
             body += chunk("id3 ", id3Tag(), littleEndian: true)
             body += chunk("data", audio, littleEndian: true)
             return Data("RIFF".utf8) + Data(leUInt32(UInt32(body.count))) + body
         }(),
         mustSurvive: unknownID3 + [("bext chunk", Data([UInt8](repeating: 0x7E, count: 60)))])

exercise("guard.flac",
         contents: {
             let streamInfo = Data([UInt8](repeating: 0x11, count: 34))
             var comment = Data(leUInt32(1)) + Data("x".utf8)
             let entries = ["TITLE=Original", "SERATO_ANALYSIS=v2.1"]
             comment += Data(leUInt32(UInt32(entries.count)))
             for e in entries { comment += Data(leUInt32(UInt32(e.utf8.count))) + Data(e.utf8) }

             var out = Data("fLaC".utf8)
             for (i, block) in [(UInt8(0), streamInfo), (UInt8(4), comment),
                                (UInt8(6), artwork)].enumerated() {
                 out += Data([block.0 | (i == 2 ? 0x80 : 0)])
                 out += Data([UInt8(block.1.count >> 16), UInt8((block.1.count >> 8) & 0xFF),
                              UInt8(block.1.count & 0xFF)])
                 out += block.1
             }
             return out + audio
         }(),
         mustSurvive: [("PICTURE block", artwork),
                       ("unknown comment", Data("SERATO_ANALYSIS=v2.1".utf8)),
                       ("audio payload", audio)])

print("")
if failures.isEmpty {
    print("All tag preservation checks passed.")
    exit(0)
}
print("\(failures.count) check(s) failed:")
for f in failures { print("  - \(f)") }
exit(1)
