import SwiftUI

struct SearchField: View {
    @Bindable var state: AppState
    let palette: Theme.Palette

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(palette.faint)
            TextField("Search all tracks", text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.crate(11.5))
                .foregroundStyle(palette.ink)
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
        .overlay(Rectangle().strokeBorder(palette.ruleStrong, lineWidth: 1))
    }
}
