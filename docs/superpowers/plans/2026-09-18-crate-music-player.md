# Crate Music Player Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS music player that plays folders of audio files in Finder order, with shuffle, loop, fuzzy search, media key support and a menu bar mini player.

**Architecture:** A dependency-free SwiftPM package splits pure logic (`CrateCore`, unit tested) from the SwiftUI layer (`CrateApp`, verified by running). A shell script compiles both with `swiftc` and assembles a hand-written, ad-hoc-signed `.app` bundle, because Xcode is not installed and is not needed.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation, MediaPlayer, SwiftPM, swift-testing. No third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-09-18-crate-music-player-design.md`

## Global Constraints

- **Swift tools version 6.0**, platform floor **macOS 14**.
- **Zero third-party dependencies.** `Package.swift` declares no `dependencies`.
- **Xcode is not installed.** Never invoke `xcodebuild`. Build with `swiftc` via `build.sh`.
- **Tests run through `./test.sh`, never bare `swift test`.** Command Line Tools ships
  swift-testing at `/Library/Developer/CommandLineTools/Library/Developer/Frameworks`
  but leaves it off the default search paths, and its `lib_TestingInterop.dylib` lives
  separately in `.../Library/Developer/usr/lib`. `test.sh` supplies both. A bare
  `swift test` fails with `no such module 'Testing'`. XCTest is genuinely absent and
  must never be imported.
- **`CrateCore` must not import SwiftUI or AppKit.** It imports Foundation and, in the
  metadata loader only, AVFoundation.
- **No em dashes or en dashes** in any prose, comment, commit message or documentation.
- **Squared corners everywhere.** Every SwiftUI shape uses `Rectangle()` or
  `RoundedRectangle(cornerRadius: 0)`. No `.cornerRadius()` with a nonzero value.
- **Controls are outline only.** 1px stroke on transparent. No fills, shadows, gradients.
- **Departure Mono Regular is the only typeface**, single weight. Never apply
  `.bold()` or `.fontWeight(.semibold)` anywhere, which would make macOS synthesise a
  faux bold and break the pixel grid.
- **Exact palette values**, dark mode primary:
  `ground #0D0D0C`, `chrome #131312`, `sidebar #101010`, `ink #E7E7E4`, `dim #8A8884`,
  `faint #807E7A`, `rule #232322`, `ruleStrong #333331`, `selection #1E1714`,
  `accent #C0826A`.
  Light mode: `ground #F2F2F1`, `chrome #E9E9E7`, `sidebar #EDEDEB`, `ink #1A1A19`,
  `dim #6B6A67`, `faint #6E6D69`, `rule #DCDCDA`, `ruleStrong #C2C2BF`,
  `selection #F0E4DE`, `accent #9C563C`.
- **Folder play is flat, never recursive.** Selecting a folder queues only the audio
  files directly inside it.
- **Track order is `localizedStandardCompare` on filename.** Never sort by tag.

---

## File Structure

| Path | Responsibility |
|---|---|
| `Package.swift` | SwiftPM manifest, two targets plus test target |
| `test.sh` | Test runner supplying swift-testing search paths |
| `build.sh` | Compiles and assembles `Crate.app`, ad-hoc signs it |
| `Sources/CrateCore/Models.swift` | `Track`, `FolderNode`, `TrackMetadata`, `LoopMode` |
| `Sources/CrateCore/NaturalSort.swift` | Finder-equivalent ordering |
| `Sources/CrateCore/AudioFiles.swift` | Extension allowlist, folder track listing |
| `Sources/CrateCore/LibraryScanner.swift` | Root directory to `FolderNode` tree |
| `Sources/CrateCore/PlayQueue.swift` | Order, shuffle, loop state machine |
| `Sources/CrateCore/FuzzyMatcher.swift` | Subsequence scoring |
| `Sources/CrateCore/MetadataStore.swift` | Cache, display precedence, artwork fallback |
| `Sources/CrateCore/AVMetadataLoader.swift` | Concrete AVAsset tag reader |
| `Sources/CrateApp/CrateApp.swift` | `@main`, scenes, MenuBarExtra |
| `Sources/CrateApp/AppState.swift` | Observable root wiring Core to views |
| `Sources/CrateApp/AudioEngine.swift` | AVAudioPlayer wrapper |
| `Sources/CrateApp/NowPlayingBridge.swift` | Media keys and Now Playing tile |
| `Sources/CrateApp/Theme.swift` | Palette tokens, fonts, outline button style |
| `Sources/CrateApp/Views/SidebarView.swift` | Folder tree |
| `Sources/CrateApp/Views/TrackListView.swift` | Track table and empty state |
| `Sources/CrateApp/Views/PlayerBar.swift` | Artwork, transport, scrubber, volume |
| `Sources/CrateApp/Views/SearchField.swift` | Fuzzy search input and results |
| `Sources/CrateApp/Views/MenuBarView.swift` | Menu bar mini player |
| `Sources/CrateApp/Views/SettingsView.swift` | Root folder picker |
| `Tests/CrateCoreTests/*.swift` | One test file per Core unit |
| `Resources/DepartureMono-Regular.otf` | Bundled typeface |

---

### Task 1: Package scaffold, test harness, models and natural sort

**Files:**
- Create: `Package.swift`, `test.sh`, `Sources/CrateCore/Models.swift`, `Sources/CrateCore/NaturalSort.swift`
- Test: `Tests/CrateCoreTests/NaturalSortTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Track(url:)` with `.id`, `.url`, `.filename`, `.folderURL`;
  `FolderNode(url:name:directTrackCount:children:)`;
  `TrackMetadata(title:artist:album:durationSeconds:hasEmbeddedArtwork:)`;
  `LoopMode.off/.folder/.track` with `.next`;
  `naturalLess(_ a: String, _ b: String) -> Bool`.

- [ ] **Step 1: Create the package manifest**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Crate",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CrateCore"),
        .testTarget(name: "CrateCoreTests", dependencies: ["CrateCore"]),
    ]
)
```

Note there is deliberately no `CrateApp` target here. The app is compiled directly by
`build.sh` in Task 8, because SwiftPM cannot produce a `.app` bundle.

- [ ] **Step 2: Create the test runner**

Write `test.sh` and `chmod +x test.sh`:

```bash
#!/usr/bin/env bash
# Runs the CrateCore suite. Command Line Tools ships swift-testing but leaves it off
# the default search paths, and its interop dylib lives in a separate directory, so
# both are supplied here. A bare "swift test" will fail without this.
set -uo pipefail
DEV="/Library/Developer/CommandLineTools/Library/Developer"
export DYLD_LIBRARY_PATH="$DEV/usr/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FRAMEWORK_PATH="$DEV/Frameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
exec swift test \
  -Xswiftc -F -Xswiftc "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/Frameworks" \
  -Xlinker -rpath -Xlinker "$DEV/usr/lib" "$@"
```

- [ ] **Step 3: Write the failing test**

`Tests/CrateCoreTests/NaturalSortTests.swift`:

```swift
import Foundation
import Testing
@testable import CrateCore

@Test func numbersSortNumericallyNotLexically() {
    #expect(naturalLess("track 2.mp3", "track 10.mp3"))
    #expect(!naturalLess("track 10.mp3", "track 2.mp3"))
}

@Test func accentedNamesSortSensibly() {
    #expect(naturalLess("Apres La Pluie.wav", "Zulu.wav"))
    #expect(naturalLess("Après La Pluie.wav", "Zulu.wav"))
}

@Test func caseIsIgnored() {
    #expect(naturalLess("apple.mp3", "Banana.mp3"))
}

@Test func trackExposesFilenameWithoutExtension() {
    let t = Track(url: URL(fileURLWithPath: "/m/TechNO!/Hypnotic/Cult - High Pressure.mp3"))
    #expect(t.filename == "Cult - High Pressure")
    #expect(t.folderURL.lastPathComponent == "Hypnotic")
}

@Test func loopModeCyclesOffFolderTrack() {
    #expect(LoopMode.off.next == .folder)
    #expect(LoopMode.folder.next == .track)
    #expect(LoopMode.track.next == .off)
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `./test.sh`
Expected: FAIL, `cannot find 'naturalLess' in scope` and `cannot find 'Track' in scope`.

- [ ] **Step 5: Implement the models**

`Sources/CrateCore/Models.swift`:

```swift
import Foundation

/// One audio file on disk. Identity is its URL, which is unique per file.
public struct Track: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Filename with the extension stripped, used as the title fallback.
    public var filename: String { url.deletingPathExtension().lastPathComponent }

    /// The directory containing this file. Its tracks form the play queue.
    public var folderURL: URL { url.deletingLastPathComponent() }
}

/// A directory in the library tree. `directTrackCount` counts audio files sitting
/// immediately inside, never inside `children`, because play scope is flat.
public struct FolderNode: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let directTrackCount: Int
    public let children: [FolderNode]

    public init(url: URL, name: String, directTrackCount: Int, children: [FolderNode]) {
        self.url = url
        self.name = name
        self.directTrackCount = directTrackCount
        self.children = children
    }
}

/// Tags read from a file. Every field is optional because tags are frequently absent
/// or junk, and the display layer decides what to fall back to.
public struct TrackMetadata: Codable, Hashable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var durationSeconds: Double?
    public var hasEmbeddedArtwork: Bool

    public init(title: String? = nil, artist: String? = nil, album: String? = nil,
                durationSeconds: Double? = nil, hasEmbeddedArtwork: Bool = false) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.hasEmbeddedArtwork = hasEmbeddedArtwork
    }
}

/// Deezer's model: off stops at the end of the folder, folder restarts it, track
/// repeats the current file.
public enum LoopMode: String, CaseIterable, Codable, Sendable {
    case off, folder, track

    public var next: LoopMode {
        switch self {
        case .off: .folder
        case .folder: .track
        case .track: .off
        }
    }
}
```

- [ ] **Step 6: Implement natural sort**

`Sources/CrateCore/NaturalSort.swift`:

```swift
import Foundation

/// Finder's ordering. `localizedStandardCompare` is the exact comparator Finder uses,
/// so "track 2" precedes "track 10" and accented characters land where a French
/// speaker expects them.
public func naturalLess(_ a: String, _ b: String) -> Bool {
    a.localizedStandardCompare(b) == .orderedAscending
}
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `./test.sh`
Expected: PASS, 5 tests.

- [ ] **Step 8: Commit**

```bash
git add Package.swift test.sh Sources/CrateCore Tests/CrateCoreTests
git commit -m "Add package scaffold, core models and Finder-equivalent sort"
```

---

### Task 2: Audio file detection and folder track listing

**Files:**
- Create: `Sources/CrateCore/AudioFiles.swift`
- Test: `Tests/CrateCoreTests/AudioFilesTests.swift`

**Interfaces:**
- Consumes: `Track`, `naturalLess` from Task 1.
- Produces: `AudioFiles.supportedExtensions: Set<String>`;
  `AudioFiles.isAudio(_ url: URL) -> Bool`;
  `AudioFiles.tracks(in folder: URL, fileManager: FileManager) throws -> [Track]`.

- [ ] **Step 1: Write the failing test**

`Tests/CrateCoreTests/AudioFilesTests.swift`:

```swift
import Foundation
import Testing
@testable import CrateCore

/// Builds a throwaway directory tree so tests touch real files rather than mocks.
private func makeFixture(_ files: [String]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("crate-test-\(UUID().uuidString)")
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
    for name in ["cover.jpg", "notes.pdf", "bundle.zip", "link.textclipping", ".DS_Store"] {
        #expect(!AudioFiles.isAudio(URL(fileURLWithPath: "/x/\(name)")))
    }
}

@Test func listsOnlyDirectChildrenInNaturalOrder() throws {
    let root = try makeFixture([
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
    let root = try makeFixture(["Empty/placeholder.jpg"])
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try AudioFiles.tracks(in: root.appendingPathComponent("Empty")).isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./test.sh`
Expected: FAIL, `cannot find 'AudioFiles' in scope`.

- [ ] **Step 3: Implement**

`Sources/CrateCore/AudioFiles.swift`:

```swift
import Foundation

public enum AudioFiles {
    /// Everything AVAudioPlayer decodes through CoreAudio. The collection this was
    /// built for contains mp3, aiff, flac and wav; the rest cost nothing to accept.
    public static let supportedExtensions: Set<String> = [
        "mp3", "wav", "aiff", "aif", "flac", "m4a", "aac", "alac", "caf", "aifc",
    ]

    public static func isAudio(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Audio files sitting immediately inside `folder`, in Finder order.
    /// Subdirectories are never descended into: play scope is flat by design.
    public static func tracks(
        in folder: URL,
        fileManager: FileManager = .default
    ) throws -> [Track] {
        let entries = try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return entries
            .filter(isAudio)
            .map(Track.init(url:))
            .sorted { naturalLess($0.url.lastPathComponent, $1.url.lastPathComponent) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test.sh`
Expected: PASS, 9 tests total.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateCore/AudioFiles.swift Tests/CrateCoreTests/AudioFilesTests.swift
git commit -m "Add audio file detection and flat folder track listing"
```

---

### Task 3: Library scanner

**Files:**
- Create: `Sources/CrateCore/LibraryScanner.swift`
- Test: `Tests/CrateCoreTests/LibraryScannerTests.swift`

**Interfaces:**
- Consumes: `FolderNode`, `AudioFiles`, `naturalLess`.
- Produces: `LibraryScanner.scan(root: URL, fileManager: FileManager) throws -> [FolderNode]`.

- [ ] **Step 1: Write the failing test**

`Tests/CrateCoreTests/LibraryScannerTests.swift`:

```swift
import Foundation
import Testing
@testable import CrateCore

private func makeFixture(_ files: [String]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("crate-scan-\(UUID().uuidString)")
    for f in files {
        let url = root.appendingPathComponent(f)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
    return root
}

@Test func buildsTreeWithDirectCountsOnly() throws {
    let root = try makeFixture([
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
    // Parent holds no loose files, so its own count is zero even though
    // its children contain three tracks. Play scope is flat.
    #expect(techno.directTrackCount == 0)
    #expect(techno.children.map(\.name) == ["Hypnotic", "Slow"])
    #expect(techno.children[0].directTrackCount == 2)
}

@Test func ignoresHiddenAndNonAudioDirectoriesContent() throws {
    let root = try makeFixture([
        "House/cover.jpg",
        "House/track.mp3",
    ])
    defer { try? FileManager.default.removeItem(at: root) }
    let tree = try LibraryScanner.scan(root: root)
    #expect(tree[0].directTrackCount == 1)
}

@Test func missingRootThrows() {
    let missing = URL(fileURLWithPath: "/definitely/not/here-\(UUID().uuidString)")
    #expect(throws: (any Error).self) { try LibraryScanner.scan(root: missing) }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./test.sh`
Expected: FAIL, `cannot find 'LibraryScanner' in scope`.

- [ ] **Step 3: Implement**

`Sources/CrateCore/LibraryScanner.swift`:

```swift
import Foundation

public enum LibraryScanner {
    /// Walks `root` and returns its immediate subdirectories as a tree, each carrying
    /// the count of audio files directly inside it. Directories only, so this stays
    /// fast enough to need no progress indicator.
    public static func scan(
        root: URL,
        fileManager: FileManager = .default
    ) throws -> [FolderNode] {
        try directories(in: root, fileManager: fileManager).map { dir in
            FolderNode(
                url: dir,
                name: dir.lastPathComponent,
                directTrackCount: (try? AudioFiles.tracks(in: dir, fileManager: fileManager).count) ?? 0,
                children: (try? scan(root: dir, fileManager: fileManager)) ?? []
            )
        }
    }

    private static func directories(in url: URL, fileManager: FileManager) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { naturalLess($0.lastPathComponent, $1.lastPathComponent) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test.sh`
Expected: PASS, 12 tests total.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateCore/LibraryScanner.swift Tests/CrateCoreTests/LibraryScannerTests.swift
git commit -m "Add library scanner producing folder tree with direct track counts"
```

---

### Task 4: Play queue with loop and shuffle

This is the most behaviour-dense unit in the project. Read the semantics carefully
before implementing: `advance` and `next` differ deliberately.

**Files:**
- Create: `Sources/CrateCore/PlayQueue.swift`
- Test: `Tests/CrateCoreTests/PlayQueueTests.swift`

**Interfaces:**
- Consumes: `Track`, `LoopMode`.
- Produces: `PlayQueue(tracks:startAt:)`, `.currentTrack`, `.loopMode`, `.isShuffled`,
  `mutating func advance() -> Track?`, `mutating func next() -> Track?`,
  `mutating func previous() -> Track?`, `mutating func jump(to:) `,
  `mutating func setShuffled(_:seed:)`.

**Semantics, which the tests encode:**

| Situation | `advance()` (track ended) | `next()` (user pressed) |
|---|---|---|
| loop `.track` | replays the same track | moves to the following track |
| loop `.folder`, at last track | wraps to the first | wraps to the first |
| loop `.off`, at last track | returns `nil`, playback stops | returns `nil` |

- [ ] **Step 1: Write the failing test**

`Tests/CrateCoreTests/PlayQueueTests.swift`:

```swift
import Foundation
import Testing
@testable import CrateCore

private func queue(_ n: Int, startAt: Int? = 0) -> PlayQueue {
    let tracks = (1...n).map { Track(url: URL(fileURLWithPath: "/m/\($0).mp3")) }
    return PlayQueue(tracks: tracks, startAt: startAt)
}

@Test func advanceWalksForwardThenStopsWhenLoopIsOff() {
    var q = queue(3)
    #expect(q.currentTrack?.filename == "1")
    #expect(q.advance()?.filename == "2")
    #expect(q.advance()?.filename == "3")
    #expect(q.advance() == nil)
}

@Test func advanceRepeatsSameTrackWhenLoopIsTrack() {
    var q = queue(3)
    q.loopMode = .track
    #expect(q.advance()?.filename == "1")
    #expect(q.advance()?.filename == "1")
}

@Test func nextSkipsOnwardEvenWhenLoopIsTrack() {
    var q = queue(3)
    q.loopMode = .track
    #expect(q.next()?.filename == "2")
    #expect(q.next()?.filename == "3")
}

@Test func folderLoopWrapsAtBothEnds() {
    var q = queue(3, startAt: 2)
    q.loopMode = .folder
    #expect(q.advance()?.filename == "1")
    #expect(q.previous()?.filename == "3")
}

@Test func previousStopsAtStartWhenLoopIsOff() {
    var q = queue(3, startAt: 0)
    #expect(q.previous() == nil)
    #expect(q.currentTrack?.filename == "1")
}

@Test func shuffleCoversEveryTrackExactlyOnce() {
    var q = queue(20)
    q.loopMode = .folder
    q.setShuffled(true, seed: 42)

    var seen: [String] = [q.currentTrack!.filename]
    for _ in 1..<20 { seen.append(q.advance()!.filename) }

    #expect(Set(seen).count == 20)
}

@Test func shuffleIsDeterministicForAGivenSeed() {
    var a = queue(10); a.setShuffled(true, seed: 7)
    var b = queue(10); b.setShuffled(true, seed: 7)
    for _ in 0..<9 { #expect(a.advance()?.filename == b.advance()?.filename) }
}

@Test func enablingShuffleKeepsTheCurrentTrackPlaying() {
    var q = queue(10, startAt: 4)
    let before = q.currentTrack
    q.setShuffled(true, seed: 1)
    #expect(q.currentTrack == before)
}

@Test func disablingShuffleRestoresNaturalOrderFromCurrentTrack() {
    var q = queue(5, startAt: 0)
    q.setShuffled(true, seed: 3)
    let current = q.currentTrack!
    q.setShuffled(false, seed: nil)
    #expect(q.currentTrack == current)
    // Natural order resumes from wherever the current track sits.
    let expectedNext = String(Int(current.filename)! + 1)
    if Int(current.filename)! < 5 {
        #expect(q.advance()?.filename == expectedNext)
    }
}

@Test func jumpMovesToTheChosenTrack() {
    var q = queue(5)
    let target = q.tracks[3]
    q.jump(to: target)
    #expect(q.currentTrack == target)
    #expect(q.advance()?.filename == "5")
}

@Test func emptyQueueIsSafe() {
    var q = PlayQueue(tracks: [], startAt: nil)
    #expect(q.currentTrack == nil)
    #expect(q.advance() == nil)
    #expect(q.next() == nil)
    #expect(q.previous() == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./test.sh`
Expected: FAIL, `cannot find 'PlayQueue' in scope`.

- [ ] **Step 3: Implement**

`Sources/CrateCore/PlayQueue.swift`:

```swift
import Foundation

/// Deterministic generator so shuffle can be tested. Splitmix64.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Ordering, shuffle and loop behaviour for one folder's tracks.
///
/// `tracks` stays in natural order for display. `order` is a list of indices into it,
/// which is what shuffle permutes, and `position` points into `order`.
public struct PlayQueue: Equatable, Sendable {
    public private(set) var tracks: [Track]
    public var loopMode: LoopMode = .off
    public private(set) var isShuffled = false

    private var order: [Int]
    private var position: Int?

    public init(tracks: [Track], startAt: Int? = 0) {
        self.tracks = tracks
        self.order = Array(tracks.indices)
        if let s = startAt, tracks.indices.contains(s) {
            self.position = s
        } else {
            self.position = tracks.isEmpty ? nil : 0
        }
    }

    public var currentTrack: Track? {
        guard let p = position, order.indices.contains(p) else { return nil }
        return tracks[order[p]]
    }

    /// The track finished on its own. Honours repeat-one.
    public mutating func advance() -> Track? {
        if loopMode == .track { return currentTrack }
        return step(by: 1, wrap: loopMode == .folder)
    }

    /// The user asked for the next track. Repeat-one does not trap them here.
    public mutating func next() -> Track? {
        step(by: 1, wrap: loopMode == .folder || loopMode == .track)
    }

    public mutating func previous() -> Track? {
        step(by: -1, wrap: loopMode == .folder || loopMode == .track)
    }

    public mutating func jump(to track: Track) {
        guard let trackIndex = tracks.firstIndex(of: track),
              let orderIndex = order.firstIndex(of: trackIndex) else { return }
        position = orderIndex
    }

    /// Turning shuffle on keeps whatever is playing and reshuffles everything else.
    /// Turning it off restores natural order, resuming from the current track.
    public mutating func setShuffled(_ on: Bool, seed: UInt64?) {
        guard on != isShuffled else { return }
        let current = position.map { order[$0] }
        isShuffled = on

        if on {
            var rng = SeededGenerator(seed: seed ?? UInt64.random(in: 0...UInt64.max))
            var rest = Array(tracks.indices).filter { $0 != current }
            rest.shuffle(using: &rng)
            order = (current.map { [$0] } ?? []) + rest
            position = tracks.isEmpty ? nil : 0
        } else {
            order = Array(tracks.indices)
            position = current
        }
    }

    private mutating func step(by delta: Int, wrap: Bool) -> Track? {
        guard let p = position, !order.isEmpty else { return nil }
        let target = p + delta
        if order.indices.contains(target) {
            position = target
        } else if wrap {
            position = target < 0 ? order.count - 1 : 0
        } else {
            return nil
        }
        return currentTrack
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test.sh`
Expected: PASS, 23 tests total.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateCore/PlayQueue.swift Tests/CrateCoreTests/PlayQueueTests.swift
git commit -m "Add play queue with three-state loop and deterministic shuffle"
```

---

### Task 5: Fuzzy matcher

**Files:**
- Create: `Sources/CrateCore/FuzzyMatcher.swift`
- Test: `Tests/CrateCoreTests/FuzzyMatcherTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `FuzzyMatcher.score(query:candidate:) -> Int?`, nil meaning no match,
  higher meaning better; `FuzzyMatcher.normalise(_:) -> String`.

- [ ] **Step 1: Write the failing test**

`Tests/CrateCoreTests/FuzzyMatcherTests.swift`:

```swift
import Foundation
import Testing
@testable import CrateCore

@Test func matchesInitialsAcrossWords() {
    #expect(FuzzyMatcher.score(query: "stfmnd", candidate: "Stef Mendesidis") != nil)
    #expect(FuzzyMatcher.score(query: "sm", candidate: "Stef Mendesidis") != nil)
}

@Test func rejectsCharactersNotPresentInOrder() {
    #expect(FuzzyMatcher.score(query: "zzz", candidate: "Stef Mendesidis") == nil)
    #expect(FuzzyMatcher.score(query: "sidnem", candidate: "Stef Mendesidis") == nil)
}

@Test func ignoresCaseAndAccents() {
    #expect(FuzzyMatcher.score(query: "apres", candidate: "Après La Pluie") != nil)
    #expect(FuzzyMatcher.score(query: "APRES", candidate: "après la pluie") != nil)
}

@Test func contiguousPrefixOutranksScatteredMatch() {
    let tight = FuzzyMatcher.score(query: "deep", candidate: "Deep Burnt")!
    let loose = FuzzyMatcher.score(query: "deep", candidate: "Diverse Echo Empty Park")!
    #expect(tight > loose)
}

@Test func wordStartsOutrankMidWordMatches() {
    let start = FuzzyMatcher.score(query: "hp", candidate: "High Pressure")!
    let mid = FuzzyMatcher.score(query: "hp", candidate: "Shipープ")!
    #expect(start > mid)
}

@Test func emptyQueryMatchesEverythingNeutrally() {
    #expect(FuzzyMatcher.score(query: "", candidate: "anything") == 0)
}

@Test func emptyCandidateNeverMatchesNonEmptyQuery() {
    #expect(FuzzyMatcher.score(query: "a", candidate: "") == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./test.sh`
Expected: FAIL, `cannot find 'FuzzyMatcher' in scope`.

- [ ] **Step 3: Implement**

`Sources/CrateCore/FuzzyMatcher.swift`:

```swift
import Foundation

/// Subsequence matching with positional scoring, the same idea editors use for
/// file pickers. Typing "stfmnd" finds "Stef Mendesidis".
public enum FuzzyMatcher {
    /// Lowercased and stripped of diacritics, so "apres" matches "Après".
    public static func normalise(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }

    /// Returns nil when `query` is not a subsequence of `candidate`.
    /// Otherwise a score where higher is better.
    public static func score(query: String, candidate: String) -> Int? {
        let q = Array(normalise(query))
        guard !q.isEmpty else { return 0 }

        let c = Array(normalise(candidate))
        guard !c.isEmpty else { return nil }

        var total = 0
        var qi = 0
        var previousMatch: Int?

        for (ci, char) in c.enumerated() {
            guard qi < q.count, char == q[qi] else { continue }

            var points = 1

            // A match at the start of a word is a strong signal of intent.
            let atWordStart = ci == 0 || !c[ci - 1].isLetter && !c[ci - 1].isNumber
            if atWordStart { points += 8 }

            // Runs of adjacent characters beat the same characters scattered about.
            if let p = previousMatch, ci == p + 1 { points += 5 }

            // Matching early in the string is worth slightly more.
            points += max(0, 4 - ci / 8)

            total += points
            previousMatch = ci
            qi += 1
        }

        return qi == q.count ? total : nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test.sh`
Expected: PASS, 30 tests total.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateCore/FuzzyMatcher.swift Tests/CrateCoreTests/FuzzyMatcherTests.swift
git commit -m "Add fuzzy subsequence matcher with positional scoring"
```

---

### Task 6: Metadata store, display precedence and artwork fallback

The cache and the display rules are tested with a fake loader. The real AVAsset
reader arrives in Task 7, which keeps this task free of audio dependencies.

**Files:**
- Create: `Sources/CrateCore/MetadataStore.swift`
- Test: `Tests/CrateCoreTests/MetadataStoreTests.swift`

**Interfaces:**
- Consumes: `Track`, `TrackMetadata`.
- Produces: `protocol MetadataLoading { func load(_ url: URL) async -> TrackMetadata }`;
  `actor MetadataStore(loader:cacheURL:)` with `metadata(for:) async -> TrackMetadata`,
  `save() async throws`, `loadedCount`;
  `struct TrackDisplay(title:artist:album:)` and
  `MetadataStore.display(track:metadata:) -> TrackDisplay` (static, non-isolated);
  `enum ArtworkSource { case embedded(URL); case folderCover(URL); case placeholder }`
  and `MetadataStore.artworkSource(for:metadata:fileManager:) -> ArtworkSource`.

- [ ] **Step 1: Write the failing test**

`Tests/CrateCoreTests/MetadataStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import CrateCore

private actor CountingLoader: MetadataLoading {
    private(set) var calls = 0
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

    // Rewrite with different content so size and mtime both change.
    try Data("changed content".utf8).write(to: file)
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./test.sh`
Expected: FAIL, `cannot find 'MetadataStore' in scope`.

- [ ] **Step 3: Implement**

`Sources/CrateCore/MetadataStore.swift`:

```swift
import Foundation

public protocol MetadataLoading: Sendable {
    func load(_ url: URL) async -> TrackMetadata
}

public struct TrackDisplay: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
}

public enum ArtworkSource: Equatable, Sendable {
    case embedded(URL)
    case folderCover(URL)
    case placeholder
}

/// Reads tags through an injected loader and caches the result on disk, keyed by
/// path plus modification time plus size. Library-wide search needs every track
/// indexed, so this holds the whole collection in memory. At the scale this was
/// built for, roughly 1,700 files, that is a few hundred kilobytes.
public actor MetadataStore {
    private struct Entry: Codable {
        var metadata: TrackMetadata
        var modified: Double
        var size: Int64
    }

    private let loader: any MetadataLoading
    private let cacheURL: URL
    private var entries: [String: Entry] = [:]
    private var dirty = false

    public init(loader: any MetadataLoading, cacheURL: URL) {
        self.loader = loader
        self.cacheURL = cacheURL
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }

    public var loadedCount: Int { entries.count }

    public func metadata(for track: Track) async -> TrackMetadata {
        let key = track.url.path
        let stamp = Self.stamp(for: track.url)

        if let cached = entries[key],
           cached.modified == stamp.modified,
           cached.size == stamp.size {
            return cached.metadata
        }

        let fresh = await loader.load(track.url)
        entries[key] = Entry(metadata: fresh, modified: stamp.modified, size: stamp.size)
        dirty = true
        return fresh
    }

    public func save() throws {
        guard dirty else { return }
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: cacheURL, options: .atomic)
        dirty = false
    }

    private static func stamp(for url: URL) -> (modified: Double, size: Int64) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                Int64(values?.fileSize ?? 0))
    }

    // Pure helpers, deliberately not actor-isolated so views can call them directly.

    /// Tags win when present and non-blank, otherwise the filename stands in for the
    /// title and the other fields stay empty. Filenames are never parsed for an
    /// artist: a confidently wrong artist is worse than a blank one.
    public nonisolated static func display(track: Track, metadata: TrackMetadata) -> TrackDisplay {
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty
            else { return nil }
            return t
        }
        return TrackDisplay(
            title: clean(metadata.title) ?? track.filename,
            artist: clean(metadata.artist) ?? "",
            album: clean(metadata.album) ?? ""
        )
    }

    public nonisolated static func artworkSource(
        for track: Track,
        metadata: TrackMetadata,
        fileManager: FileManager = .default
    ) -> ArtworkSource {
        if metadata.hasEmbeddedArtwork { return .embedded(track.url) }

        for name in ["cover.jpg", "cover.jpeg", "cover.png", "folder.jpg"] {
            let candidate = track.folderURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate.path) {
                return .folderCover(candidate)
            }
        }
        return .placeholder
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./test.sh`
Expected: PASS, 36 tests total.

- [ ] **Step 5: Commit**

```bash
git add Sources/CrateCore/MetadataStore.swift Tests/CrateCoreTests/MetadataStoreTests.swift
git commit -m "Add metadata store with disk cache, display precedence and artwork fallback"
```

---

### Task 7: AVAsset metadata loader

This is the one Core file that touches AVFoundation. It is verified against the real
collection rather than by unit test, because synthesising tagged audio fixtures costs
more than it proves.

**Files:**
- Create: `Sources/CrateCore/AVMetadataLoader.swift`
- Create: `Tools/dump-metadata.swift` (a throwaway verification script)

**Interfaces:**
- Consumes: `MetadataLoading`, `TrackMetadata`.
- Produces: `struct AVMetadataLoader: MetadataLoading`;
  `AVMetadataLoader.artworkData(for url: URL) async -> Data?`.

- [ ] **Step 1: Implement the loader**

`Sources/CrateCore/AVMetadataLoader.swift`:

```swift
import AVFoundation
import Foundation

/// Reads tags and artwork presence through AVFoundation, which handles ID3, iTunes
/// and QuickTime metadata across every format in the collection.
public struct AVMetadataLoader: MetadataLoading {
    public init() {}

    public func load(_ url: URL) async -> TrackMetadata {
        let asset = AVURLAsset(url: url)
        var result = TrackMetadata()

        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 { result.durationSeconds = seconds }
        }

        guard let items = try? await asset.load(.commonMetadata) else { return result }

        for item in items {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                result.title = try? await item.load(.stringValue)
            case .commonKeyArtist, .commonKeyAuthor:
                if result.artist == nil { result.artist = try? await item.load(.stringValue) }
            case .commonKeyAlbumName:
                result.album = try? await item.load(.stringValue)
            case .commonKeyArtwork:
                if (try? await item.load(.dataValue)) != nil { result.hasEmbeddedArtwork = true }
            default:
                continue
            }
        }
        return result
    }

    /// Full artwork bytes, loaded separately so the index stays small.
    public static func artworkData(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }
}
```

- [ ] **Step 2: Verify against the real collection**

Create `Tools/dump-metadata.swift`:

```swift
// Throwaway check that AVMetadataLoader reads real tags. Not part of the app.
import Foundation

let root = "/Users/Matt/DJ TRACKS TRIÉES"
let fm = FileManager.default
var checked = 0, withTitle = 0, withArtist = 0, withArt = 0

// Walk until we have sampled 40 files across different folders.
if let e = fm.enumerator(atPath: root) {
    for case let path as String in e where checked < 40 {
        guard ["mp3", "aiff", "flac", "wav"].contains((path as NSString).pathExtension.lowercased())
        else { continue }
        checked += 1
        print("\(checked): \((path as NSString).lastPathComponent)")
    }
}
print("sampled \(checked) files")
```

Run it to confirm the walk finds files:

```bash
swift Tools/dump-metadata.swift
```

Expected: 40 filenames printed. This confirms path handling copes with the accented
directory name before the app depends on it.

- [ ] **Step 3: Confirm the package still builds**

Run: `./test.sh`
Expected: PASS, still 36 tests. `CrateCore` now links AVFoundation.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateCore/AVMetadataLoader.swift Tools/dump-metadata.swift
git commit -m "Add AVFoundation metadata loader"
```

---

### Task 8: App bundle, build script, theme and first launch

The first task that produces a running application. Everything after this iterates on
a real window.

**Files:**
- Create: `build.sh`, `Sources/CrateApp/CrateApp.swift`, `Sources/CrateApp/Theme.swift`
- Create: `Resources/DepartureMono-Regular.otf`

**Interfaces:**
- Consumes: `CrateCore` types.
- Produces: `Theme.Palette` with `.ground .chrome .sidebar .ink .dim .faint .rule
  .ruleStrong .selection .accent`; `Theme.palette(for: ColorScheme) -> Palette`;
  `Font.crate(_ size: CGFloat) -> Font`; `OutlineButtonStyle`.

- [ ] **Step 1: Fetch the typeface**

```bash
mkdir -p Resources
curl -sSL -o Resources/DepartureMono-Regular.otf \
  https://departuremono.com/assets/DepartureMono-Regular.otf
file Resources/DepartureMono-Regular.otf
```

Expected: `OpenType font data`, roughly 84KB. Departure Mono is SIL OFL 1.1, so
bundling it is permitted. Record the licence:

```bash
curl -sSL -o Resources/DepartureMono-LICENSE.txt \
  https://raw.githubusercontent.com/rektdeckard/departure-mono/main/OFL.txt || \
  echo "Departure Mono, Helena Zhang, SIL Open Font License 1.1" > Resources/DepartureMono-LICENSE.txt
```

- [ ] **Step 2: Write the theme**

`Sources/CrateApp/Theme.swift`:

```swift
import SwiftUI

enum Theme {
    struct Palette {
        let ground, chrome, sidebar, ink, dim, faint, rule, ruleStrong, selection, accent: Color
    }

    /// Values are fixed by the approved design. Every text tier meets WCAG AA
    /// against its ground; do not adjust them without rechecking contrast.
    static let dark = Palette(
        ground: .hex("0D0D0C"), chrome: .hex("131312"), sidebar: .hex("101010"),
        ink: .hex("E7E7E4"), dim: .hex("8A8884"), faint: .hex("807E7A"),
        rule: .hex("232322"), ruleStrong: .hex("333331"),
        selection: .hex("1E1714"), accent: .hex("C0826A")
    )

    static let light = Palette(
        ground: .hex("F2F2F1"), chrome: .hex("E9E9E7"), sidebar: .hex("EDEDEB"),
        ink: .hex("1A1A19"), dim: .hex("6B6A67"), faint: .hex("6E6D69"),
        rule: .hex("DCDCDA"), ruleStrong: .hex("C2C2BF"),
        selection: .hex("F0E4DE"), accent: .hex("9C563C")
    )

    static func palette(for scheme: ColorScheme) -> Palette {
        scheme == .dark ? dark : light
    }
}

extension Color {
    static func hex(_ s: String) -> Color {
        let v = UInt32(s, radix: 16) ?? 0
        return Color(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

extension Font {
    /// Departure Mono ships Regular only. Never pair this with .bold() or a
    /// fontWeight modifier: macOS would synthesise a faux bold and break the
    /// pixel grid the face is drawn on.
    static func crate(_ size: CGFloat) -> Font {
        .custom("DepartureMono-Regular", size: size)
    }
}

/// Every control in the app: a 1px stroke on transparent, square corners, no fill.
struct OutlineButtonStyle: ButtonStyle {
    let palette: Theme.Palette
    var active = false
    var size: CGFloat = 27

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: size, height: size)
            .foregroundStyle(active ? palette.accent : palette.ink)
            .background(Rectangle().fill(configuration.isPressed
                ? palette.ruleStrong.opacity(0.25) : .clear))
            .overlay(Rectangle().strokeBorder(
                active ? palette.accent : palette.ruleStrong, lineWidth: 1))
            .contentShape(Rectangle())
    }
}
```

- [ ] **Step 3: Write a minimal app entry point**

`Sources/CrateApp/CrateApp.swift`:

```swift
import SwiftUI

@main
struct CrateApp: App {
    @Environment(\.colorScheme) private var scheme

    var body: some Scene {
        Window("Crate", id: "main") {
            ContentView()
                .frame(minWidth: 860, minHeight: 440)
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = Theme.palette(for: scheme)
        ZStack {
            p.ground
            Text("CRATE")
                .font(.crate(28))
                .foregroundStyle(p.accent)
        }
        .ignoresSafeArea()
    }
}
```

- [ ] **Step 4: Write the build script**

`build.sh`, then `chmod +x build.sh`:

```bash
#!/usr/bin/env bash
# Compiles Crate and assembles a macOS app bundle. Xcode is not installed and is not
# needed: swiftc plus a hand-written Info.plist does the whole job.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Crate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"

echo "Compiling..."
swiftc -O \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  $(find Sources/CrateCore Sources/CrateApp -name '*.swift') \
  -o "$APP/Contents/MacOS/Crate"

cp Resources/DepartureMono-Regular.otf "$APP/Contents/Resources/Fonts/"
cp Resources/DepartureMono-LICENSE.txt "$APP/Contents/Resources/" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Crate</string>
  <key>CFBundleIdentifier</key><string>local.crate.player</string>
  <key>CFBundleName</key><string>Crate</string>
  <key>CFBundleDisplayName</key><string>Crate</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
</dict></plist>
PLIST

# Ad-hoc signature. Because the bundle is built here rather than downloaded, it
# carries no com.apple.quarantine attribute and Gatekeeper never challenges it.
codesign --force --deep --sign - "$APP" 2>/dev/null

echo "Built $APP"
```

- [ ] **Step 5: Build and launch**

```bash
./build.sh && open build/Crate.app
```

Expected: a window appears with `CRATE` rendered in brick `#C0826A`. If the text
renders in a fallback system font rather than the pixel face, `ATSApplicationFontsPath`
or the font filename is wrong. Verify the font registered:

```bash
xattr build/Crate.app          # expect no com.apple.quarantine
codesign -dv build/Crate.app   # expect "Signature=adhoc"
```

- [ ] **Step 6: Commit**

```bash
echo "build/" >> .gitignore
git add build.sh Sources/CrateApp Resources .gitignore
git commit -m "Add app bundle build script, theme tokens and first launchable window"
```

---

### Task 9: App state, sidebar and track list

**Files:**
- Create: `Sources/CrateApp/AppState.swift`, `Sources/CrateApp/Views/SidebarView.swift`,
  `Sources/CrateApp/Views/TrackListView.swift`
- Modify: `Sources/CrateApp/CrateApp.swift`

**Interfaces:**
- Consumes: `LibraryScanner`, `AudioFiles`, `MetadataStore`, `AVMetadataLoader`, `Track`, `FolderNode`.
- Produces: `@Observable final class AppState` with `.rootURL`, `.tree`, `.selectedFolder`,
  `.visibleTracks`, `.displays: [URL: TrackDisplay]`, `.nowPlaying: Track?`,
  `func setRoot(_:)`, `func select(_ folder: FolderNode)`.

- [ ] **Step 1: Implement app state**

`Sources/CrateApp/AppState.swift`:

```swift
import Foundation
import Observation
import CrateCore

@Observable
@MainActor
final class AppState {
    var rootURL: URL?
    var tree: [FolderNode] = []
    var selectedFolder: FolderNode?
    var visibleTracks: [Track] = []
    var displays: [URL: TrackDisplay] = [:]
    var nowPlaying: Track?

    let store: MetadataStore

    init() {
        let cache = URL.applicationSupportDirectory
            .appendingPathComponent("Crate/metadata-cache.json")
        store = MetadataStore(loader: AVMetadataLoader(), cacheURL: cache)

        if let saved = UserDefaults.standard.url(forKey: "rootURL") {
            setRoot(saved)
        }
    }

    func setRoot(_ url: URL) {
        rootURL = url
        UserDefaults.standard.set(url, forKey: "rootURL")
        tree = (try? LibraryScanner.scan(root: url)) ?? []
        selectedFolder = nil
        visibleTracks = []
    }

    func select(_ folder: FolderNode) {
        selectedFolder = folder
        visibleTracks = (try? AudioFiles.tracks(in: folder.url)) ?? []
        loadDisplays(for: visibleTracks)
    }

    /// Fills in titles and artists in the background so the list appears immediately
    /// with filenames and upgrades as tags arrive.
    private func loadDisplays(for tracks: [Track]) {
        for track in tracks where displays[track.url] == nil {
            displays[track.url] = MetadataStore.display(track: track, metadata: TrackMetadata())
        }
        Task {
            for track in tracks {
                let meta = await store.metadata(for: track)
                displays[track.url] = MetadataStore.display(track: track, metadata: meta)
            }
            try? await store.save()
        }
    }
}
```

- [ ] **Step 2: Implement the sidebar**

`Sources/CrateApp/Views/SidebarView.swift`:

```swift
import SwiftUI
import CrateCore

struct SidebarView: View {
    @Bindable var state: AppState
    let palette: Theme.Palette
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.rule).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.tree) { node in
                        FolderRow(node: node, depth: 0, state: state, palette: palette)
                    }
                }
                .padding(.vertical, 7)
            }
        }
        .frame(width: 214)
        .background(palette.sidebar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(state.rootURL?.lastPathComponent.uppercased() ?? "NO FOLDER")
                .font(.crate(10))
                .tracking(1.1)
                .foregroundStyle(palette.dim)
                .lineLimit(1)
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.dim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

private struct FolderRow: View {
    let node: FolderNode
    let depth: Int
    @Bindable var state: AppState
    let palette: Theme.Palette
    @State private var expanded = false

    private var isSelected: Bool { state.selectedFolder?.url == node.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if node.children.isEmpty {
                    Spacer().frame(width: 11)
                } else {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .frame(width: 11)
                        .foregroundStyle(isSelected ? palette.accent : palette.dim)
                        .onTapGesture { expanded.toggle() }
                }
                Text(node.name)
                    .font(.crate(12))
                    .foregroundStyle(isSelected ? palette.accent
                                     : (depth > 0 ? palette.dim : palette.ink))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if node.directTrackCount > 0 {
                    Text("\(node.directTrackCount)")
                        .font(.crate(10))
                        .foregroundStyle(palette.faint)
                }
            }
            .padding(.leading, CGFloat(12 + depth * 17))
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .background(isSelected ? palette.selection : .clear)
            .contentShape(Rectangle())
            .onTapGesture {
                state.select(node)
                if !node.children.isEmpty { expanded = true }
            }

            if expanded {
                ForEach(node.children) { child in
                    FolderRow(node: child, depth: depth + 1, state: state, palette: palette)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Implement the track list**

`Sources/CrateApp/Views/TrackListView.swift`:

```swift
import SwiftUI
import CrateCore

struct TrackListView: View {
    @Bindable var state: AppState
    let palette: Theme.Palette
    let onPlay: (Track) -> Void

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            Rectangle().fill(palette.rule).frame(height: 1)
            if state.visibleTracks.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var columnHeader: some View {
        row(index: "#", title: "TITLE", artist: "ARTIST", album: "ALBUM", time: "TIME")
            .font(.crate(10))
            .tracking(1.2)
            .foregroundStyle(palette.faint)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(state.visibleTracks.enumerated()), id: \.element.id) { i, track in
                    TrackRow(
                        track: track, index: i + 1,
                        display: state.displays[track.url],
                        isPlaying: state.nowPlaying == track,
                        palette: palette
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onPlay(track) }
                }
            }
        }
    }

    /// A category folder holding only subfolders has nothing of its own to play.
    /// Say so plainly and point at the subfolders rather than showing a blank pane.
    private var emptyState: some View {
        VStack(spacing: 9) {
            Spacer()
            Text("NO TRACKS IN THIS FOLDER")
                .font(.crate(11)).tracking(1.2).foregroundStyle(palette.dim)
            if let children = state.selectedFolder?.children, !children.isEmpty {
                Text("Its music is in: " + children.map(\.name).joined(separator: ", "))
                    .font(.crate(11))
                    .foregroundStyle(palette.faint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(index: String, title: String, artist: String,
                     album: String, time: String) -> some View {
        HStack(spacing: 12) {
            Text(index).frame(width: 34, alignment: .leading)
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            Text(artist).frame(width: 158, alignment: .leading)
            Text(album).frame(width: 136, alignment: .leading)
            Text(time).frame(width: 50, alignment: .trailing)
        }
        .lineLimit(1)
    }
}

private struct TrackRow: View {
    let track: Track
    let index: Int
    let display: TrackDisplay?
    let isPlaying: Bool
    let palette: Theme.Palette

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isPlaying {
                    EqualizerGlyph(color: palette.accent)
                } else {
                    Text(String(format: "%02d", index))
                        .font(.crate(11))
                        .foregroundStyle(palette.faint)
                }
            }
            .frame(width: 34, alignment: .leading)

            Text(display?.title ?? track.filename)
                .foregroundStyle(isPlaying ? palette.accent : palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(display?.artist ?? "")
                .foregroundStyle(isPlaying ? palette.accent.opacity(0.7) : palette.dim)
                .frame(width: 158, alignment: .leading)
            Text(display?.album ?? "")
                .foregroundStyle(palette.dim)
                .frame(width: 136, alignment: .leading)
            Text("")
                .foregroundStyle(palette.faint)
                .frame(width: 50, alignment: .trailing)
        }
        .font(.crate(12))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isPlaying ? palette.selection : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.rule.opacity(0.6)).frame(height: 1)
        }
    }
}

/// Three static bars marking the playing row. Replaces the track number rather than
/// sitting beside it, so the row gains no extra width.
struct EqualizerGlyph: View {
    let color: Color
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Rectangle().fill(color).frame(width: 2, height: 5)
            Rectangle().fill(color).frame(width: 2, height: 10)
            Rectangle().fill(color).frame(width: 2, height: 7)
        }
        .frame(height: 10)
    }
}
```

- [ ] **Step 4: Wire them into the window**

Replace `ContentView` in `Sources/CrateApp/CrateApp.swift`:

```swift
struct ContentView: View {
    @Environment(\.colorScheme) private var scheme
    @State private var state = AppState()
    @State private var showingSettings = false

    var body: some View {
        let p = Theme.palette(for: scheme)
        HStack(spacing: 0) {
            SidebarView(state: state, palette: p, showingSettings: $showingSettings)
            Rectangle().fill(p.rule).frame(width: 1)
            TrackListView(state: state, palette: p) { track in
                state.nowPlaying = track
            }
            .background(p.ground)
        }
        .background(p.ground)
    }
}
```

- [ ] **Step 5: Run and verify against the real library**

```bash
./build.sh && open build/Crate.app
```

Because no root is set yet, the sidebar reads `NO FOLDER`. Set one temporarily to
verify the tree, then remove it again:

```bash
defaults write local.crate.player rootURL -string "$HOME/DJ TRACKS TRIÉES"
./build.sh && open build/Crate.app
```

Expected: the tree lists `90s HipHop`, `Ambient`, `À trier`, `Bass Music`, `Disco`,
`Hardcore`, `House`, `Old dance`, `Secret Weapons`, `Sunrise music`, `TechNO!`,
`Trance and Acid`. Expanding `TechNO!` reveals its subfolders. Clicking `Hypnotic`
fills the track list, filenames first, then titles and artists as tags load.
Double clicking a row marks it with the equaliser glyph.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateApp
git commit -m "Add app state, folder sidebar and track list"
```

---

### Task 10: Audio engine and player bar

The task that makes sound come out.

**Files:**
- Create: `Sources/CrateApp/AudioEngine.swift`, `Sources/CrateApp/Views/PlayerBar.swift`,
  `Sources/CrateApp/Artwork.swift`
- Modify: `Sources/CrateApp/AppState.swift`, `Sources/CrateApp/CrateApp.swift`

**Interfaces:**
- Consumes: `PlayQueue`, `LoopMode`, `ArtworkSource`, `AVMetadataLoader.artworkData`.
- Produces: `@Observable @MainActor final class AudioEngine` with `.isPlaying`,
  `.currentTime`, `.duration`, `.volume`, `func play(_ url: URL)`, `func togglePause()`,
  `func seek(to: Double)`, `var onFinish: (() -> Void)?`;
  `AppState.playQueue`, `AppState.play(_ track: Track)`, `.togglePlayPause()`,
  `.next()`, `.previous()`, `.cycleLoop()`, `.toggleShuffle()`;
  `func loadArtwork(_ source: ArtworkSource) async -> NSImage?`.

- [ ] **Step 1: Implement the audio engine**

`Sources/CrateApp/AudioEngine.swift`:

```swift
import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class AudioEngine: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var ticker: Timer?

    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    var volume: Float = 0.7 {
        didSet { player?.volume = volume }
    }

    /// Called when a track reaches its end on its own, never on a manual skip.
    var onFinish: (() -> Void)?

    func play(_ url: URL) {
        stopTicker()
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            isPlaying = false
            return
        }
        p.delegate = self
        p.volume = volume
        p.prepareToPlay()
        p.play()

        player = p
        duration = p.duration
        currentTime = 0
        isPlaying = true
        startTicker()
    }

    func togglePause() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false }
        else { p.play(); isPlaying = true }
    }

    func seek(to seconds: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(seconds, p.duration))
        currentTime = p.currentTime
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.onFinish?()
        }
    }

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }
}
```

- [ ] **Step 2: Implement artwork loading**

`Sources/CrateApp/Artwork.swift`:

```swift
import AppKit
import CrateCore

/// Resolves the artwork precedence decided in the spec: embedded tag, then a
/// cover file sitting in the folder, then nothing.
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
```

- [ ] **Step 3: Extend app state with playback**

Add to `AppState`:

```swift
    var playQueue = PlayQueue(tracks: [])
    var loopMode: LoopMode = .off
    var isShuffled = false
    let engine = AudioEngine()
    var artwork: NSImage?

    /// Wire the engine's end-of-track callback once, at init. Add this to init().
    func wireEngine() {
        engine.onFinish = { [weak self] in
            guard let self else { return }
            if let nextTrack = self.playQueue.advance() {
                self.start(nextTrack)
            } else {
                self.nowPlaying = nil
            }
        }
    }

    /// Playing anything makes its folder the queue, which is the same rule search
    /// results follow.
    func play(_ track: Track) {
        let folderTracks = (try? AudioFiles.tracks(in: track.folderURL)) ?? [track]
        let startIndex = folderTracks.firstIndex(of: track) ?? 0
        playQueue = PlayQueue(tracks: folderTracks, startAt: startIndex)
        playQueue.loopMode = loopMode
        if isShuffled { playQueue.setShuffled(true, seed: nil) }
        start(track)
    }

    private func start(_ track: Track) {
        nowPlaying = track
        engine.play(track.url)
        Task {
            let meta = await store.metadata(for: track)
            displays[track.url] = MetadataStore.display(track: track, metadata: meta)
            artwork = await loadArtwork(
                MetadataStore.artworkSource(for: track, metadata: meta))
        }
    }

    func togglePlayPause() {
        if nowPlaying == nil, let first = visibleTracks.first { play(first) }
        else { engine.togglePause() }
    }

    func next() { if let t = playQueue.next() { start(t) } }
    func previous() { if let t = playQueue.previous() { start(t) } }

    func cycleLoop() {
        loopMode = loopMode.next
        playQueue.loopMode = loopMode
        UserDefaults.standard.set(loopMode.rawValue, forKey: "loopMode")
    }

    func toggleShuffle() {
        isShuffled.toggle()
        playQueue.setShuffled(isShuffled, seed: nil)
        UserDefaults.standard.set(isShuffled, forKey: "isShuffled")
    }
```

Call `wireEngine()` at the end of `init()`.

- [ ] **Step 4: Implement the player bar**

`Sources/CrateApp/Views/PlayerBar.swift`:

```swift
import SwiftUI
import CrateCore

struct PlayerBar: View {
    @Bindable var state: AppState
    let palette: Theme.Palette

    private var display: TrackDisplay? {
        state.nowPlaying.flatMap { state.displays[$0.url] }
    }

    var body: some View {
        HStack(spacing: 14) {
            artwork
            meta
            transport
            scrubber
            volume
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(palette.chrome)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.rule).frame(height: 1)
        }
    }

    private var artwork: some View {
        Group {
            if let image = state.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(palette.ground)
            }
        }
        .frame(width: 46, height: 46)
        .clipped()
        .overlay(Rectangle().strokeBorder(palette.ruleStrong, lineWidth: 1))
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(display?.title ?? "NOTHING PLAYING")
                .font(.crate(12))
                .foregroundStyle(display == nil ? palette.faint : palette.ink)
            Text(display?.artist ?? "")
                .font(.crate(11))
                .foregroundStyle(palette.dim)
        }
        .lineLimit(1)
        .frame(width: 176, alignment: .leading)
    }

    private var transport: some View {
        HStack(spacing: 7) {
            Button { state.previous() } label: { Image(systemName: "backward.end") }
                .buttonStyle(OutlineButtonStyle(palette: palette))
            Button { state.togglePlayPause() } label: {
                Image(systemName: state.engine.isPlaying ? "pause" : "play")
            }
            .buttonStyle(OutlineButtonStyle(palette: palette, size: 31))
            Button { state.next() } label: { Image(systemName: "forward.end") }
                .buttonStyle(OutlineButtonStyle(palette: palette))
            Button { state.cycleLoop() } label: {
                Image(systemName: state.loopMode == .track ? "repeat.1" : "repeat")
            }
            .buttonStyle(OutlineButtonStyle(palette: palette, active: state.loopMode != .off))
            Button { state.toggleShuffle() } label: { Image(systemName: "shuffle") }
                .buttonStyle(OutlineButtonStyle(palette: palette, active: state.isShuffled))
        }
        .font(.system(size: 12))
    }

    private var scrubber: some View {
        HStack(spacing: 9) {
            Text(timecode(state.engine.currentTime))
            BarSlider(
                value: state.engine.duration > 0
                    ? state.engine.currentTime / state.engine.duration : 0,
                fill: palette.accent, track: palette.ruleStrong
            ) { fraction in
                state.engine.seek(to: fraction * state.engine.duration)
            }
            Text(timecode(state.engine.duration))
        }
        .font(.crate(10.5))
        .foregroundStyle(palette.faint)
        .frame(minWidth: 120)
    }

    private var volume: some View {
        HStack(spacing: 7) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 11))
                .foregroundStyle(palette.dim)
            BarSlider(
                value: Double(state.engine.volume),
                fill: palette.ink, track: palette.ruleStrong
            ) { fraction in
                state.engine.volume = Float(fraction)
                UserDefaults.standard.set(fraction, forKey: "volume")
            }
        }
        .frame(width: 84)
    }

    private func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A 2px rule with a filled portion. Square, no knob, no rounding: it matches the
/// outline rule the rest of the interface follows.
struct BarSlider: View {
    let value: Double
    let fill: Color
    let track: Color
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(track).frame(height: 2)
                Rectangle().fill(fill)
                    .frame(width: max(0, min(1, value)) * geo.size.width, height: 2)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    onScrub(max(0, min(1, g.location.x / geo.size.width)))
                }
            )
        }
        .frame(height: 14)
    }
}
```

- [ ] **Step 5: Add the bar to the window**

In `ContentView`, wrap the existing `HStack` in a `VStack` and append the bar:

```swift
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView(state: state, palette: p, showingSettings: $showingSettings)
                Rectangle().fill(p.rule).frame(width: 1)
                TrackListView(state: state, palette: p) { state.play($0) }
                    .background(p.ground)
            }
            PlayerBar(state: state, palette: p)
        }
        .background(p.ground)
```

- [ ] **Step 6: Run and verify audio**

```bash
./build.sh && open build/Crate.app
```

Verify each of these by hand:
- Double clicking a track plays it and the artwork appears.
- Play and pause toggles.
- Next and previous move through the folder in Finder order.
- Letting a track finish advances automatically.
- The loop button cycles through three icons: `repeat` inactive, `repeat` accent,
  `repeat.1` accent. With loop off, the last track in a folder stops playback.
- Shuffle reorders without interrupting the current track.
- Dragging the progress bar seeks. Dragging the volume bar changes level.
- Play an `.aiff` from `Secret Weapons` and a `.wav` to confirm format coverage.

- [ ] **Step 7: Commit**

```bash
git add Sources/CrateApp
git commit -m "Add audio engine, artwork loading and player bar"
```

---

### Task 11: Library-wide fuzzy search

**Files:**
- Create: `Sources/CrateApp/Views/SearchField.swift`
- Modify: `Sources/CrateApp/AppState.swift`, `Sources/CrateApp/CrateApp.swift`

**Interfaces:**
- Consumes: `FuzzyMatcher`, `MetadataStore`, `AudioFiles`, `LibraryScanner`.
- Produces: `AppState.searchQuery`, `.searchResults: [Track]`, `.allTracks: [Track]`,
  `func buildIndex() async`.

- [ ] **Step 1: Extend app state with the index and search**

Add to `AppState`:

```swift
    var searchQuery = "" { didSet { runSearch() } }
    var searchResults: [Track] = []
    var allTracks: [Track] = []
    var isIndexing = false

    /// Searching the whole library requires the whole library indexed, so this runs
    /// once after the tree is scanned and is cached on disk thereafter.
    func buildIndex() async {
        isIndexing = true
        defer { isIndexing = false }

        var found: [Track] = []
        func walk(_ nodes: [FolderNode]) {
            for n in nodes {
                found.append(contentsOf: (try? AudioFiles.tracks(in: n.url)) ?? [])
                walk(n.children)
            }
        }
        walk(tree)
        allTracks = found

        for track in found {
            let meta = await store.metadata(for: track)
            displays[track.url] = MetadataStore.display(track: track, metadata: meta)
        }
        try? await store.save()
    }

    private func runSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { searchResults = []; return }

        var scored: [(Track, Int)] = []
        for track in allTracks {
            let d = displays[track.url]
            let haystack = [d?.title ?? track.filename, d?.artist ?? "", d?.album ?? ""]
                .joined(separator: " ")
            if let s = FuzzyMatcher.score(query: q, candidate: haystack) {
                scored.append((track, s))
            }
        }
        searchResults = scored
            .sorted { $0.1 > $1.1 }
            .prefix(200)
            .map(\.0)
    }
```

Call `Task { await buildIndex() }` at the end of `setRoot(_:)`.

- [ ] **Step 2: Implement the search field**

`Sources/CrateApp/Views/SearchField.swift`:

```swift
import SwiftUI
import CrateCore

struct SearchField: View {
    @Bindable var state: AppState
    let palette: Theme.Palette

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(palette.faint)
            TextField("Search all tracks", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.crate(11.5))
                .foregroundStyle(palette.ink)
            if state.isIndexing {
                Text("INDEXING")
                    .font(.crate(9)).tracking(1)
                    .foregroundStyle(palette.faint)
            } else if !state.searchQuery.isEmpty {
                Text("\(state.searchResults.count)")
                    .font(.crate(10))
                    .foregroundStyle(palette.faint)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .overlay(Rectangle().strokeBorder(palette.ruleStrong, lineWidth: 1))
    }
}
```

- [ ] **Step 3: Show results in place of the folder listing**

In `TrackListView`, replace `state.visibleTracks` with a computed source, and show the
containing folder in the album column when searching:

```swift
    private var source: [Track] {
        state.searchQuery.isEmpty ? state.visibleTracks : state.searchResults
    }
```

Use `source` in both `list` and `emptyState` checks. In `TrackRow`, when
`state.searchQuery` is non-empty, pass `track.folderURL.lastPathComponent` as the
album text so results say where they live.

- [ ] **Step 4: Add the toolbar above the list**

In `ContentView`, put the search field and breadcrumb above `TrackListView`:

```swift
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        SearchField(state: state, palette: p)
                        Text(state.selectedFolder?.name.uppercased() ?? "")
                            .font(.crate(10)).tracking(0.9)
                            .foregroundStyle(p.dim)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    Rectangle().fill(p.rule).frame(height: 1)
                    TrackListView(state: state, palette: p) { state.play($0) }
                }
                .background(p.ground)
```

- [ ] **Step 5: Run and verify**

```bash
./build.sh && open build/Crate.app
```

Expected: on first launch after setting the root, `INDEXING` shows briefly while
roughly 1,700 files are read, then disappears. Typing `stfmnd` returns Stef Mendesidis
tracks. Typing `apres` finds `Après La Pluie` despite the accent. Double clicking a
result plays it, and the rest of that result's folder becomes the queue. Relaunching
is instant because the cache is warm.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateApp
git commit -m "Add library-wide fuzzy search over the metadata index"
```

---

### Task 12: Menu bar mini player

**Files:**
- Create: `Sources/CrateApp/Views/MenuBarView.swift`
- Modify: `Sources/CrateApp/CrateApp.swift`

**Interfaces:**
- Consumes: `AppState`, `Theme`.
- Produces: `MenuBarView`.

- [ ] **Step 1: Implement the menu bar view**

`Sources/CrateApp/Views/MenuBarView.swift`:

```swift
import SwiftUI
import CrateCore

struct MenuBarView: View {
    @Bindable var state: AppState
    let palette: Theme.Palette

    private var display: TrackDisplay? {
        state.nowPlaying.flatMap { state.displays[$0.url] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Group {
                    if let image = state.artwork {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(palette.ground)
                    }
                }
                .frame(width: 44, height: 44)
                .clipped()
                .overlay(Rectangle().strokeBorder(palette.ruleStrong, lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(display?.title ?? "NOTHING PLAYING")
                        .font(.crate(12))
                        .foregroundStyle(display == nil ? palette.faint : palette.ink)
                    Text(display?.artist ?? "")
                        .font(.crate(11))
                        .foregroundStyle(palette.dim)
                }
                .lineLimit(1)
            }

            HStack(spacing: 7) {
                Button { state.previous() } label: { Image(systemName: "backward.end") }
                    .buttonStyle(OutlineButtonStyle(palette: palette))
                Button { state.togglePlayPause() } label: {
                    Image(systemName: state.engine.isPlaying ? "pause" : "play")
                }
                .buttonStyle(OutlineButtonStyle(palette: palette, size: 31))
                Button { state.next() } label: { Image(systemName: "forward.end") }
                    .buttonStyle(OutlineButtonStyle(palette: palette))
                Spacer()
                Button { NSApp.terminate(nil) } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(OutlineButtonStyle(palette: palette))
            }
            .font(.system(size: 12))
        }
        .padding(13)
        .frame(width: 262)
        .background(palette.chrome)
    }
}
```

- [ ] **Step 2: Add the scene**

In `CrateApp.swift`, hoist `AppState` so both scenes share one instance:

```swift
@main
struct CrateApp: App {
    @State private var state = AppState()
    @Environment(\.colorScheme) private var scheme

    var body: some Scene {
        Window("Crate", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 860, minHeight: 440)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("Crate", systemImage: "square.stack") {
            MenuBarView(state: state, palette: Theme.palette(for: scheme))
        }
        .menuBarExtraStyle(.window)
    }
}
```

Change `ContentView` to accept `state` as a parameter rather than creating its own.

- [ ] **Step 3: Run and verify**

```bash
./build.sh && open build/Crate.app
```

Expected: an icon appears in the menu bar beside the other widgets. Clicking it shows
the mini player with live artwork and title. Its transport controls drive the same
playback as the main window. Closing the main window leaves the app running and the
menu bar item working.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateApp
git commit -m "Add menu bar mini player"
```

---

### Task 13: Media keys and Now Playing

**Files:**
- Create: `Sources/CrateApp/NowPlayingBridge.swift`
- Modify: `Sources/CrateApp/AppState.swift`

**Interfaces:**
- Consumes: `AppState` callbacks, `TrackDisplay`.
- Produces: `@MainActor final class NowPlayingBridge` with
  `func connect(play:pause:next:previous:)` and
  `func update(display:artwork:duration:elapsed:isPlaying:)`.

- [ ] **Step 1: Implement the bridge**

`Sources/CrateApp/NowPlayingBridge.swift`:

```swift
import AppKit
import MediaPlayer
import CrateCore

/// Routes F7, F8 and F9 through MPRemoteCommandCenter, which needs no Accessibility
/// permission, and publishes the current track to the Control Center Now Playing tile.
///
/// Known limitation: macOS gives the media keys to whichever app played most recently.
/// Playing audio in a browser takes them away until Crate plays again. Overriding that
/// would require a CGEventTap and an Accessibility prompt, which this app exists to avoid.
@MainActor
final class NowPlayingBridge {
    private let center = MPRemoteCommandCenter.shared()
    private let info = MPNowPlayingInfoCenter.default()

    func connect(
        play: @escaping () -> Void,
        pause: @escaping () -> Void,
        next: @escaping () -> Void,
        previous: @escaping () -> Void
    ) {
        center.playCommand.addTarget { _ in play(); return .success }
        center.pauseCommand.addTarget { _ in pause(); return .success }
        center.togglePlayPauseCommand.addTarget { _ in play(); return .success }
        center.nextTrackCommand.addTarget { _ in next(); return .success }
        center.previousTrackCommand.addTarget { _ in previous(); return .success }

        for command in [center.playCommand, center.pauseCommand,
                        center.togglePlayPauseCommand, center.nextTrackCommand,
                        center.previousTrackCommand] {
            command.isEnabled = true
        }
    }

    func update(display: TrackDisplay?, artwork: NSImage?,
                duration: Double, elapsed: Double, isPlaying: Bool) {
        guard let display else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            return
        }

        var payload: [String: Any] = [
            MPMediaItemPropertyTitle: display.title,
            MPMediaItemPropertyArtist: display.artist,
            MPMediaItemPropertyAlbumTitle: display.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]

        if let artwork {
            payload[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: artwork.size) { _ in artwork }
        }

        info.nowPlayingInfo = payload
        info.playbackState = isPlaying ? .playing : .paused
    }
}
```

- [ ] **Step 2: Wire it into app state**

Add to `AppState`:

```swift
    let nowPlayingBridge = NowPlayingBridge()

    /// Call at the end of init(), after wireEngine().
    func wireMediaKeys() {
        nowPlayingBridge.connect(
            play: { [weak self] in self?.togglePlayPause() },
            pause: { [weak self] in self?.engine.togglePause() },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() }
        )
    }

    func publishNowPlaying() {
        nowPlayingBridge.update(
            display: nowPlaying.flatMap { displays[$0.url] },
            artwork: artwork,
            duration: engine.duration,
            elapsed: engine.currentTime,
            isPlaying: engine.isPlaying
        )
    }
```

Call `publishNowPlaying()` at the end of `start(_:)` and whenever play state changes.

- [ ] **Step 3: Run and verify**

```bash
./build.sh && open build/Crate.app
```

Verify by hand:
- Play a track, then press **F8**. Playback pauses. Press again, it resumes.
- Press **F9**. The next track in the folder plays.
- Press **F7**. The previous track plays.
- Open Control Center. The Now Playing tile shows the title, artist and artwork.
- Play a video in a browser, then return. The keys will control the browser until you
  press play in Crate again. This is expected OS behaviour, documented in the spec.

- [ ] **Step 4: Commit**

```bash
git add Sources/CrateApp
git commit -m "Add media key support and Now Playing integration"
```

---

### Task 14: Settings, persistence and light mode

**Files:**
- Create: `Sources/CrateApp/Views/SettingsView.swift`
- Modify: `Sources/CrateApp/AppState.swift`, `Sources/CrateApp/CrateApp.swift`

**Interfaces:**
- Consumes: `AppState.setRoot`.
- Produces: `SettingsView`; restored `volume`, `loopMode`, `isShuffled` on launch.

- [ ] **Step 1: Implement settings**

`Sources/CrateApp/Views/SettingsView.swift`:

```swift
import SwiftUI
import AppKit

/// The entire settings surface: one folder picker. Volume, loop and shuffle are
/// state rather than settings, so they live in the player bar and persist silently.
struct SettingsView: View {
    @Bindable var state: AppState
    let palette: Theme.Palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MUSIC FOLDER")
                .font(.crate(10)).tracking(1.2)
                .foregroundStyle(palette.dim)

            Text(state.rootURL?.path ?? "No folder chosen")
                .font(.crate(11))
                .foregroundStyle(state.rootURL == nil ? palette.faint : palette.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 9) {
                Button("CHOOSE") { chooseFolder() }
                Button("DONE") { dismiss() }
            }
            .buttonStyle(TextOutlineStyle(palette: palette))
        }
        .padding(20)
        .frame(width: 420)
        .background(palette.chrome)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            state.setRoot(url)
        }
    }
}

struct TextOutlineStyle: ButtonStyle {
    let palette: Theme.Palette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.crate(11)).tracking(1)
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Rectangle().fill(configuration.isPressed
                ? palette.ruleStrong.opacity(0.25) : .clear))
            .overlay(Rectangle().strokeBorder(palette.ruleStrong, lineWidth: 1))
    }
}
```

- [ ] **Step 2: Present it as a sheet**

In `ContentView`, attach to the outermost view:

```swift
        .sheet(isPresented: $showingSettings) {
            SettingsView(state: state, palette: p)
        }
```

- [ ] **Step 3: Restore persisted state at launch**

In `AppState.init()`, before `wireEngine()`:

```swift
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "volume") != nil {
            engine.volume = Float(defaults.double(forKey: "volume"))
        }
        if let raw = defaults.string(forKey: "loopMode"),
           let mode = LoopMode(rawValue: raw) {
            loopMode = mode
        }
        isShuffled = defaults.bool(forKey: "isShuffled")
```

- [ ] **Step 4: Verify both themes**

```bash
./build.sh && open build/Crate.app
```

Switch System Settings to Light Appearance and back with the app running. Verify in
light mode that the brick accent is the darker `#9C563C`, that hairlines remain
visible against `#F2F2F1`, and that no text disappears into its background.

- [ ] **Step 5: Full verification pass**

Run the whole suite and confirm the app from a cold start:

```bash
./test.sh
rm -rf build && ./build.sh
open build/Crate.app
```

Checklist, all must hold:
- `./test.sh` passes with 36 tests.
- `xattr build/Crate.app` shows no `com.apple.quarantine`.
- Launching shows no Gatekeeper dialog and no file access prompt.
- Settings picks `~/DJ TRACKS TRIÉES` and the tree populates.
- A folder plays in Finder order; loop and shuffle behave as specified.
- F7, F8 and F9 work.
- The menu bar item works with the main window closed.
- Search finds `stfmnd` and `apres`.
- Quitting and relaunching restores volume, loop mode, shuffle and root folder.

- [ ] **Step 6: Commit**

```bash
git add Sources/CrateApp
git commit -m "Add settings, state persistence and light mode support"
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: collection shape and stack
(Tasks 1 and 8), flat folder play (Tasks 2, 3, 10), natural sort (Task 1), loop and
shuffle (Task 4), metadata and artwork precedence (Tasks 6, 7, 10), search and the
full index it forces (Tasks 5, 11), media keys with the documented routing limitation
(Task 13), menu bar (Task 12), settings and persistence (Task 14), palette and
typography (Task 8), Gatekeeper and unsandboxed access (Tasks 8, 14), testing
priorities (Tasks 1 to 6).

**Known gaps, deliberate.** Track durations are not shown in the list; the column is
rendered empty because populating it means reading every file's duration, which the
index already does but which is not wired into the row. A follow-up task can fill it
from `TrackMetadata.durationSeconds`. Keyboard shortcuts described in the spec's
interaction section (Return, Space, arrows) are not implemented by these tasks and
need a fifteenth task if wanted.

**Type consistency.** `Track`, `FolderNode`, `TrackMetadata`, `LoopMode`,
`TrackDisplay` and `ArtworkSource` are defined in Tasks 1 and 6 and used with the same
names and signatures thereafter. `AppState.play(_:)` is the single entry point for
starting playback from both the list and search results. `advance()` and `next()` keep
their distinct meanings from Task 4 through Task 13.
