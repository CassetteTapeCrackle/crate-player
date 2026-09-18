import AVFoundation
import Foundation
import Observation

/// Forwards AVAudioPlayer's completion callback. Kept as a separate NSObject so
/// AudioEngine itself can be a plain @Observable class.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (@Sendable () -> Void)?

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}

@Observable
@MainActor
final class AudioEngine {
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let delegate = PlayerDelegate()

    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0

    var volume: Float = 0.7 {
        didSet { player?.volume = volume }
    }

    /// Called when a track reaches its end on its own, never on a manual skip.
    @ObservationIgnored var onFinish: (() -> Void)?

    init() {
        delegate.onFinish = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.onFinish?()
            }
        }
    }

    func play(_ url: URL) {
        stopTicker()
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            isPlaying = false
            duration = 0
            currentTime = 0
            return
        }
        p.delegate = delegate
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
        if p.isPlaying {
            p.pause()
            isPlaying = false
        } else {
            p.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard let p = player, p.duration > 0 else { return }
        p.currentTime = max(0, min(seconds, p.duration))
        currentTime = p.currentTime
    }

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}
