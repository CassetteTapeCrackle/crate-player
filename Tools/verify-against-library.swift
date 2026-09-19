// Runs the tag writer over copies of real tracks and proves nothing but the three
// edited frames moved.
//
// Not part of CI: the runner has no music. This is the only check that exercises tags
// written by other software, which is where the awkward cases actually come from.
//
// Run: ./Tools/verify-against-library.sh ["/path/to/library"] [per-format count]
import AVFoundation
import Foundation
@testable import CrateCore

let arguments = CommandLine.arguments
let root = URL(fileURLWithPath: arguments.count > 1
    ? arguments[1]
    : NSHomeDirectory() + "/DJ TRACKS TRIÉES")
let perFormat = arguments.count > 2 ? (Int(arguments[2]) ?? 12) : 12

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var checked = 0
nonisolated(unsafe) var skipped = 0

func fail(_ file: String, _ why: String) {
    print("  FAIL  \(file): \(why)")
    failures += 1
}

/// Everything in the tag except the three fields we edit, keyed so it can be compared
/// before and after. Covers ID3 frames and Vorbis comments alike, since both are
/// "things the writer must not have touched".
func untouchedEntries(_ url: URL) -> [String: [Data]]? {
    guard let file = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    var out: [String: [Data]] = [:]

    if url.pathExtension.lowercased() == "flac" {
        guard let comment = flacComment(file) else { return nil }
        let edited: Set<String> = ["TITLE", "ARTIST", "ALBUM"]
        for entry in comment.entries where !edited.contains(entry.key.uppercased()) {
            out[entry.key.uppercased(), default: []].append(Data(entry.value.utf8))
        }
        return out
    }

    guard let kind = ID3Container.forExtension(url.pathExtension),
          let blob = try? ID3Containers.extractTag(from: file, kind: kind),
          let tag = try? ID3v2.parse(blob) else { return nil }
    let edited: Set<String> = [tag.titleFrameID, tag.artistFrameID, tag.albumFrameID]
    for frame in tag.frames where !edited.contains(frame.id) {
        out[frame.id, default: []].append(frame.payload)
    }
    return out
}

func flacComment(_ file: Data) -> VorbisComment? {
    var offset = 0
    if ID3v2.hasTag(file), let tag = try? ID3v2.parse(file) {
        offset = tag.encodedByteCount
    }
    guard file.asciiAt(offset, 4) == "fLaC" else { return nil }
    offset += 4
    while let header = file.byteAt(offset), let size = file.bigEndianUInt24At(offset + 1) {
        if header & 0x7F == FLACBlock.vorbisComment {
            return file.sliceAt(offset + 4, Int(size)).flatMap(VorbisComment.decode)
        }
        if header & 0x80 != 0 { return nil }
        offset += 4 + Int(size)
    }
    return nil
}

/// The actual samples, isolated from whatever metadata surrounds them. Comparing this
/// before and after is the claim that matters: an edit must not move one byte of audio.
func audioRegion(_ url: URL) -> Data? {
    guard let file = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    switch url.pathExtension.lowercased() {
    case "mp3":
        let start = (try? ID3v2.parse(file))??.encodedByteCount ?? 0
        let end = ID3v1.isPresent(in: file) ? file.count - ID3v1.length : file.count
        return file.sliceAt(start, max(0, end - start))
    case "aiff", "aif":
        return ID3Containers.audioPayload(file, kind: .aiff)
    case "wav", "wave":
        return ID3Containers.audioPayload(file, kind: .wave)
    case "flac":
        var offset = 0
        if ID3v2.hasTag(file), let tag = try? ID3v2.parse(file) { offset = tag.encodedByteCount }
        guard file.asciiAt(offset, 4) == "fLaC" else { return nil }
        offset += 4
        while let header = file.byteAt(offset), let size = file.bigEndianUInt24At(offset + 1) {
            offset += 4 + Int(size)
            if header & 0x80 != 0 { break }
        }
        return file.sliceAt(offset, max(0, file.count - offset))
    default:
        return nil
    }
}

func duration(_ url: URL) async -> Double? {
    let asset = AVURLAsset(url: url)
    guard let d = try? await asset.load(.duration) else { return nil }
    let seconds = CMTimeGetSeconds(d)
    return seconds.isFinite && seconds > 0 ? seconds : nil
}

let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("crate-library-verify-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workspace) }

func candidates() -> [URL] {
    guard let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]) else { return [] }
    var byExtension: [String: [URL]] = [:]
    for case let url as URL in walker {
        let ext = url.pathExtension.lowercased()
        guard ["mp3", "aiff", "aif", "wav", "flac"].contains(ext) else { continue }
        if byExtension[ext, default: []].count < perFormat { byExtension[ext, default: []].append(url) }
    }
    return byExtension.values.flatMap { $0 }.sorted { $0.path < $1.path }
}

print("Verifying against \(root.path)\n")

for original in candidates() {
    let name = original.lastPathComponent
    let copy = workspace.appendingPathComponent(name)
    guard (try? FileManager.default.copyItem(at: original, to: copy)) != nil else {
        skipped += 1
        continue
    }

    let beforeEntries = untouchedEntries(copy)
    let beforeBytes = try? Data(contentsOf: copy)
    let beforeAudio = audioRegion(copy)
    let beforeDuration = await duration(copy)

    do {
        try TagWriter.write(TagEdit(title: .set("CRATE VERIFY \(checked)"),
                                    artist: .set("Verification Run")), to: copy)
    } catch {
        fail(name, "write refused: \(error)")
        checked += 1
        continue
    }
    checked += 1

    // Every frame we do not edit must come back identical, payload for payload.
    if let before = beforeEntries, let after = untouchedEntries(copy) {
        for (id, payloads) in before where after[id] != payloads {
            fail(name, "\(id) changed")
        }
        for (id, payloads) in after where before[id] != payloads {
            fail(name, "\(id) appeared or grew")
        }
    }

    // The tag we just wrote has to read back.
    let fields = TagReader.read(copy)
    if fields?.title != "CRATE VERIFY \(checked - 1)" {
        fail(name, "title did not read back (got \(fields?.title ?? "nil"))")
    }

    // Not one sample may have moved.
    switch (beforeAudio, audioRegion(copy)) {
    case let (before?, after?) where before != after:
        fail(name, "audio payload changed (\(before.count) then \(after.count) bytes)")
    case (_?, nil):
        fail(name, "audio payload is no longer locatable")
    case (nil, _):
        fail(name, "audio payload could not be read before the edit")
    default:
        break
    }

    // And the file must still be the same piece of audio.
    let afterDuration = await duration(copy)
    switch (beforeDuration, afterDuration) {
    case let (before?, after?) where abs(before - after) > 0.05:
        fail(name, "duration moved from \(before) to \(after)")
    case (_?, nil):
        fail(name, "AVFoundation can no longer decode it")
    default:
        break
    }

    if let beforeBytes, let afterBytes = try? Data(contentsOf: copy),
       beforeBytes.count == afterBytes.count, beforeBytes == afterBytes {
        fail(name, "nothing changed at all, which means the write did not happen")
    }

    try? FileManager.default.removeItem(at: copy)
}

print("\nChecked \(checked) files, skipped \(skipped).")
if failures == 0 {
    print("No unknown frame, no audio payload and no duration changed.")
    exit(0)
}
print("\(failures) problem(s) found.")
exit(1)
