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

    let n = Int(current.filename)!
    if n < 5 { #expect(q.advance()?.filename == String(n + 1)) }
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
