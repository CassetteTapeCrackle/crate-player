import SwiftUI
import CrateCore

struct MenuBarView: View {
    @Bindable var state: AppState
    let palette: Theme.Palette

    private var display: TrackDisplay? {
        state.nowPlaying.map { state.display(for: $0) }
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
                Spacer(minLength: 0)
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
                Button { state.cycleLoop() } label: {
                    Image(systemName: state.loopMode == .track ? "repeat.1" : "repeat")
                }
                .buttonStyle(OutlineButtonStyle(palette: palette, active: state.loopMode != .off))
                Spacer(minLength: 0)
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(OutlineButtonStyle(palette: palette))
            }
            .font(.system(size: 12))
        }
        .padding(13)
        .frame(width: 268)
        .background(palette.chrome)
    }
}
