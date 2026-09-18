/// Keeps display order separate from playback order.
public struct PlayQueue: Equatable, Sendable {
    public private(set) var tracks: [Track]
    public var loopMode: LoopMode = .off
    public private(set) var isShuffled = false

    private var playbackOrder: [Int]
    private var position: Int?

    /// A nil or out-of-bounds start leaves the queue without a selection.
    public init(tracks: [Track], startAt: Int? = 0) {
        self.tracks = tracks
        playbackOrder = Array(tracks.indices)
        position = startAt.flatMap { tracks.indices.contains($0) ? $0 : nil }
    }

    public var currentTrack: Track? {
        guard let position else { return nil }
        return tracks[playbackOrder[position]]
    }

    /// Automatic completion repeats the current track in track-loop mode.
    public mutating func advance() -> Track? {
        if loopMode == .track { return currentTrack }
        return next()
    }

    /// Manual navigation bypasses single-track repeat.
    public mutating func next() -> Track? {
        guard let position else { return nil }
        if position + 1 < playbackOrder.count {
            self.position = position + 1
        } else if loopMode != .off {
            self.position = 0
        } else {
            return nil
        }
        return currentTrack
    }

    public mutating func previous() -> Track? {
        guard let position else { return nil }
        if position > 0 {
            self.position = position - 1
        } else if loopMode != .off {
            self.position = playbackOrder.count - 1
        } else {
            return nil
        }
        return currentTrack
    }

    /// Unknown tracks leave the current selection unchanged.
    public mutating func jump(to track: Track) {
        guard let index = tracks.firstIndex(of: track),
              let position = playbackOrder.firstIndex(of: index) else { return }
        self.position = position
    }

    /// Reapplying the same shuffle state is a no-op, even with a new seed.
    public mutating func setShuffled(_ on: Bool, seed: UInt64?) {
        guard on != isShuffled else { return }
        let currentIndex = position.map { playbackOrder[$0] }
        playbackOrder = Array(tracks.indices)

        if on {
            // Start a full shuffled pass at the current track. Preserve the
            // original index, including when equal tracks occur more than once.
            if let currentIndex {
                playbackOrder.remove(at: currentIndex)
            }
            var generator = SplitMix64(seed: seed ?? UInt64.random(in: .min ... .max))
            playbackOrder.shuffle(using: &generator)
            if let currentIndex {
                playbackOrder.insert(currentIndex, at: 0)
            }
            position = currentIndex == nil ? nil : 0
        } else {
            position = currentIndex
        }
        isShuffled = on
    }
}

private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
