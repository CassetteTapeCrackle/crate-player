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
            if state.listedTracks.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 34, alignment: .leading)
            Text("TITLE").frame(maxWidth: .infinity, alignment: .leading)
            Text("ARTIST").frame(width: 158, alignment: .leading)
            Text(state.isSearching ? "FOLDER" : "ALBUM").frame(width: 136, alignment: .leading)
            Text("TIME").frame(width: 50, alignment: .trailing)
        }
        .font(.crate(10))
        .tracking(1.2)
        .foregroundStyle(palette.faint)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(state.listedTracks.enumerated()), id: \.element.id) { i, track in
                    TrackRow(
                        title: state.display(for: track).title,
                        artist: state.display(for: track).artist,
                        third: state.isSearching
                            ? track.folderURL.lastPathComponent
                            : state.display(for: track).album,
                        time: timecode(state.duration(for: track)),
                        index: i + 1,
                        isPlaying: state.nowPlaying == track,
                        palette: palette
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onPlay(track) }
                }
            }
        }
    }

    /// A category folder holding only subfolders has nothing of its own to play. Say so
    /// and point at the subfolders rather than showing a blank pane.
    private var emptyState: some View {
        VStack(spacing: 9) {
            Spacer()
            Text(emptyHeadline)
                .font(.crate(11)).tracking(1.2).foregroundStyle(palette.dim)
            if let children = state.selectedFolder?.children, !children.isEmpty,
               !state.isSearching {
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

    private var emptyHeadline: String {
        if state.isSearching { return "NO MATCHES" }
        if state.rootURL == nil { return "CHOOSE A MUSIC FOLDER IN SETTINGS" }
        if state.selectedFolder == nil { return "PICK A FOLDER" }
        return "NO TRACKS IN THIS FOLDER"
    }
}

private struct TrackRow: View {
    let title: String
    let artist: String
    let third: String
    let time: String
    let index: Int
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

            Text(title)
                .foregroundStyle(isPlaying ? palette.accent : palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(artist)
                .foregroundStyle(isPlaying ? palette.accent.opacity(0.7) : palette.dim)
                .frame(width: 158, alignment: .leading)
            Text(third)
                .foregroundStyle(palette.dim)
                .frame(width: 136, alignment: .leading)
            Text(time)
                .font(.crate(11))
                .foregroundStyle(palette.faint)
                .frame(width: 50, alignment: .trailing)
        }
        .font(.crate(12))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isPlaying ? palette.selection : Color.clear)
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
