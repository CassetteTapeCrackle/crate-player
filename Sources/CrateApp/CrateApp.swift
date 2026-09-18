import SwiftUI

@main
struct CrateApp: App {
    @State private var state = AppState()
    @Environment(\.colorScheme) private var scheme

    var body: some Scene {
        Window("Crate", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 880, minHeight: 460)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("Crate", systemImage: "square.stack") {
            MenuBarView(state: state, palette: Theme.palette(for: scheme))
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @Bindable var state: AppState
    @Environment(\.colorScheme) private var scheme
    @State private var showingSettings = false

    var body: some View {
        let p = Theme.palette(for: scheme)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView(state: state, palette: p, showingSettings: $showingSettings)
                Rectangle().fill(p.rule).frame(width: 1)
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        SearchField(state: state, palette: p)
                        Text(breadcrumb)
                            .font(.crate(10)).tracking(0.9)
                            .foregroundStyle(p.dim)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    Rectangle().fill(p.rule).frame(height: 1)
                    TrackListView(state: state, palette: p) { state.play($0) }
                }
                .background(p.ground)
            }
            PlayerBar(state: state, palette: p)
        }
        .background(p.ground)
        .sheet(isPresented: $showingSettings) {
            SettingsView(state: state, palette: p)
        }
    }

    private var breadcrumb: String {
        guard let folder = state.selectedFolder else { return "" }
        guard let root = state.rootURL else { return folder.name.uppercased() }
        let relative = folder.url.path
            .replacingOccurrences(of: root.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.replacingOccurrences(of: "/", with: " / ").uppercased()
    }
}
