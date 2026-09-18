// Regression test for the artwork handler trapping off the main thread.
//
// MediaPlayer rasterises Now Playing artwork on its own dispatch queue. The request
// handler is created inside NowPlayingBridge, a @MainActor type, so if it is written
// as a plain inline closure it inherits main-actor isolation. The Swift 6 runtime
// enforces that isolation, the queue assertion fails off the main thread, and the
// process traps with SIGTRAP. Every track with embedded artwork crashed the app.
//
// This drives the real NowPlayingBridge, then calls the handler from a background
// queue exactly as MediaPlayer does. A trap kills the process, so the failure mode is
// a non-zero exit rather than an assertion message.
//
// Run: ./Tools/check-nowplaying-artwork.sh
import AppKit
import MediaPlayer
import CrateCore

enum Outcome: Int {
    case pending = 0, passed = 1, noArtwork = 2
}

nonisolated(unsafe) var outcome = Outcome.pending

@MainActor
func exercise() {
    let image = NSImage(size: NSSize(width: 16, height: 16))
    image.lockFocus()
    NSColor.orange.drawSwatch(in: NSRect(x: 0, y: 0, width: 16, height: 16))
    image.unlockFocus()

    let bridge = NowPlayingBridge()
    bridge.update(
        display: TrackDisplay(title: "Test", artist: "Test", album: "Test"),
        artwork: image,
        duration: 100,
        elapsed: 0,
        isPlaying: true
    )

    guard let published = MPNowPlayingInfoCenter.default()
        .nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork else {
        outcome = .noArtwork
        return
    }

    // MPMediaItemArtwork is not Sendable, but handing it to another queue is the
    // precise thing under test: MediaPlayer itself does exactly this.
    nonisolated(unsafe) let artwork = published
    DispatchQueue.global(qos: .userInitiated).async {
        _ = artwork.image(at: CGSize(width: 16, height: 16))   // used to trap here
        outcome = .passed
    }
}

// An NSApplication has to exist before AppKit drawing is legal.
_ = NSApplication.shared
Task { @MainActor in exercise() }

// Pump the main run loop rather than blocking it, or the main-actor work above can
// never be scheduled and this would deadlock against itself.
let limit = Date().addingTimeInterval(10)
while outcome == .pending, Date() < limit {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}

switch outcome {
case .passed:
    print("PASS: Now Playing artwork handler ran off the main thread without trapping")
    exit(0)
case .noArtwork:
    FileHandle.standardError.write("FAIL: no artwork was published\n".data(using: .utf8)!)
    exit(1)
case .pending:
    FileHandle.standardError.write("FAIL: timed out\n".data(using: .utf8)!)
    exit(1)
}
