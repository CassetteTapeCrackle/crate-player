import AppKit
import SwiftUI

@main
struct CrateApp: App {
    @State private var state = AppState()

    /// The record mark as a template image, so macOS paints it to match the menu
    /// bar in either appearance instead of us guessing a colour.
    private static let menuBarIcon: NSImage = {
        guard let url = Bundle.main.url(forResource: "menubar", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "smallcircle.filled.circle",
                           accessibilityDescription: "Crate") ?? NSImage()
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    private var loopLabel: String {
        switch state.loopMode {
        case .off: "Loop: Off"
        case .folder: "Loop: Folder"
        case .track: "Loop: Track"
        }
    }

    var body: some Scene {
        Window("Crate", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 880, minHeight: 460)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Command-modified so they never steal keys from the search field.
            CommandMenu("Playback") {
                Button(state.engine.isPlaying ? "Pause" : "Play") { state.togglePlayPause() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Next Track") { state.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous Track") { state.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button(loopLabel) { state.cycleLoop() }
                    .keyboardShortcut("l", modifiers: .command)
                Button(state.isShuffled ? "Shuffle: On" : "Shuffle: Off") { state.toggleShuffle() }
                    .keyboardShortcut("u", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarView(state: state)
        } label: {
            Image(nsImage: Self.menuBarIcon)
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
