import AppKit
import SwiftUI
import CrateCore

struct TrackListView: View {
    @Bindable var state: AppState
    let palette: Theme.Palette

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            Rectangle().fill(palette.rule).frame(height: 1)
            if state.listedTracks.isEmpty {
                emptyState
            } else {
                list
            }
            if let problem = state.writeProblem {
                Rectangle().fill(palette.rule).frame(height: 1)
                Text(problem)
                    .font(.crate(10.5))
                    .foregroundStyle(palette.accent)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
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
        // The stack is grown to at least the height of the viewport so the empty space
        // under the last row is part of the content and can be clicked. A background
        // behind the scroll view itself never receives the click.
        GeometryReader { viewport in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.listedTracks.enumerated()), id: \.element.id) { i, track in
                        TrackRow(state: state, track: track, index: i + 1, palette: palette)
                    }
                }
                .frame(minHeight: viewport.size.height, alignment: .top)
                // Behind the rows, so it only sees clicks that missed all of them.
                .background(ClickCatcher { _, _ in state.deselectAll() })
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
    @Bindable var state: AppState
    let track: Track
    let index: Int
    let palette: Theme.Palette

    @FocusState private var editing: Bool

    private var isPlaying: Bool { state.nowPlaying == track }

    var body: some View {
        let display = state.display(for: track)
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

            cell(.title, display.title).frame(maxWidth: .infinity, alignment: .leading)
            cell(.artist, display.artist).frame(width: 158, alignment: .leading)

            // Searching puts the source folder in the third column, which is not a tag.
            if state.isSearching {
                Text(track.folderURL.lastPathComponent)
                    .foregroundStyle(palette.dim)
                    .frame(width: 136, alignment: .leading)
            } else {
                cell(.album, display.album).frame(width: 136, alignment: .leading)
            }

            Text(timecode(state.duration(for: track)))
                .font(.crate(11))
                .foregroundStyle(palette.faint)
                .frame(width: 50, alignment: .trailing)
        }
        .font(.crate(12))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        // Behind the cells, so it only sees clicks that missed every piece of text.
        .background(ClickCatcher { _, modifiers in state.clickRow(track, modifiers: modifiers) })
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.rule.opacity(0.6)).frame(height: 1)
        }
    }

    /// One editable field. The click target and the selection highlight are both sized
    /// to the glyphs, so double-clicking an artist means that artist rather than the
    /// empty space beside it.
    @ViewBuilder
    private func cell(_ field: TagField, _ text: String) -> some View {
        if state.editingCell == AppState.CellRef(url: track.url, field: field) {
            TextField("", text: $state.editDraft)
                .textFieldStyle(.plain)
                .font(.crate(12))
                .foregroundStyle(palette.ink)
                .focused($editing)
                .onAppear { editing = true }
                .onSubmit { state.commitEdit() }
                .onExitCommand { state.cancelEdit() }
                .padding(.horizontal, 3)
                .overlay(Rectangle().strokeBorder(palette.accent, lineWidth: 1))
        } else {
            Text(text)
                .foregroundStyle(ink(field))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(state.isSelected(track, field) ? palette.selection : Color.clear)
                .overlay(ClickCatcher { count, modifiers in
                    state.clickCell(track, field, count: count, modifiers: modifiers)
                })
        }
    }

    private func ink(_ field: TagField) -> Color {
        guard isPlaying else { return field == .title ? palette.ink : palette.dim }
        return field == .title ? palette.accent : palette.accent.opacity(0.7)
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
