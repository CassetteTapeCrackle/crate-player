import SwiftUI

struct SearchField: View {
    @Bindable var state: AppState
    let palette: Theme.Palette

    /// Owned by ContentView so clicks elsewhere in the window can clear it.
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(focused ? palette.accent : palette.faint)
            TextField("Search all tracks", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.crate(11.5))
                .foregroundStyle(palette.ink)
                .focused($focused)
                .onExitCommand { focused = false }
            if state.isIndexing {
                Text("INDEXING")
                    .font(.crate(9)).tracking(1)
                    .foregroundStyle(palette.faint)
            } else if state.isSearching {
                Text("\(state.searchResults.count)")
                    .font(.crate(10))
                    .foregroundStyle(palette.faint)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        // The accent marks state, and "typing here" is a state worth seeing: it is
        // the difference between space playing a track and space typing a space.
        .overlay(Rectangle().strokeBorder(
            focused ? palette.accent : palette.ruleStrong, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}
