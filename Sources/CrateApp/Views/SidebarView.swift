import SwiftUI
import CrateCore

struct SidebarView: View {
    @Bindable var state: AppState
    let palette: Theme.Palette
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.rule).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.tree) { node in
                        FolderRow(node: node, depth: 0, state: state, palette: palette)
                    }
                }
                .padding(.vertical, 7)
            }
        }
        .frame(width: 214)
        .background(palette.sidebar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(state.rootURL?.lastPathComponent.uppercased() ?? "NO FOLDER")
                .font(.crate(10))
                .tracking(1.1)
                .foregroundStyle(palette.dim)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { showingSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.dim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}

private struct FolderRow: View {
    let node: FolderNode
    let depth: Int
    @Bindable var state: AppState
    let palette: Theme.Palette
    @State private var expanded = false

    private var isSelected: Bool { state.selectedFolder?.url == node.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if node.children.isEmpty {
                    Color.clear.frame(width: 11, height: 1)
                } else {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .frame(width: 11)
                        .foregroundStyle(isSelected ? palette.accent : palette.dim)
                        .onTapGesture { expanded.toggle() }
                }
                Text(node.name)
                    .font(.crate(12))
                    .foregroundStyle(isSelected ? palette.accent
                                     : (depth > 0 ? palette.dim : palette.ink))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if node.directTrackCount > 0 {
                    Text("\(node.directTrackCount)")
                        .font(.crate(10))
                        .foregroundStyle(palette.faint)
                }
            }
            .padding(.leading, CGFloat(12 + depth * 17))
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .background(isSelected ? palette.selection : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture {
                state.select(node)
                if !node.children.isEmpty { expanded = true }
            }

            if expanded {
                ForEach(node.children) { child in
                    FolderRow(node: child, depth: depth + 1, state: state, palette: palette)
                }
            }
        }
    }
}
