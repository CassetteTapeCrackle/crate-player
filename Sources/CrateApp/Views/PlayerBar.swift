import SwiftUI
import CrateCore

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
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    guard geo.size.width > 0 else { return }
                    onScrub(max(0, min(1, g.location.x / geo.size.width)))
                }
            )
        }
        .frame(height: 14)
    }
}

struct PlayerBar: View {
    @Bindable var state: AppState
    let palette: Theme.Palette

    private var display: TrackDisplay? {
        state.nowPlaying.map { state.display(for: $0) }
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
        .frame(minWidth: 130)
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
                state.setVolume(fraction)
            }
        }
        .frame(width: 84)
    }
}
