import AppKit
import MediaPlayer
import CrateCore

/// Routes F7, F8 and F9 through MPRemoteCommandCenter, which needs no Accessibility
/// permission, and publishes the current track to the Control Center Now Playing tile.
///
/// Known limitation: macOS gives the media keys to whichever app played most recently.
/// Playing audio in a browser takes them away until Crate plays again. Overriding that
/// would need a CGEventTap and an Accessibility prompt, which this app exists to avoid.
@MainActor
final class NowPlayingBridge {
    private let center = MPRemoteCommandCenter.shared()
    private let info = MPNowPlayingInfoCenter.default()

    func connect(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        next: @escaping @MainActor () -> Void,
        previous: @escaping @MainActor () -> Void
    ) {
        center.togglePlayPauseCommand.addTarget { _ in
            Task { @MainActor in play() }
            return .success
        }
        center.playCommand.addTarget { _ in
            Task { @MainActor in play() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            Task { @MainActor in pause() }
            return .success
        }
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in next() }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in previous() }
            return .success
        }

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
