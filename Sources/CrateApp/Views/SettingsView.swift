import SwiftUI
import AppKit

/// The entire settings surface: one folder picker. Volume, loop and shuffle are state
/// rather than settings, so they live in the player bar and persist silently.
struct SettingsView: View {
    @Bindable var state: AppState
    let palette: Theme.Palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MUSIC FOLDER")
                .font(.crate(10)).tracking(1.2)
                .foregroundStyle(palette.dim)

            Text(state.rootURL?.path ?? "No folder chosen")
                .font(.crate(11))
                .foregroundStyle(state.rootURL == nil ? palette.faint : palette.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Text("Crate plays the audio files sitting directly inside whichever folder you select. Subfolders appear in the tree and play separately.")
                .font(.crate(10.5))
                .foregroundStyle(palette.faint)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 9) {
                Button("CHOOSE") { chooseFolder() }
                Button("DONE") { dismiss() }
                Spacer()
            }
            .buttonStyle(TextOutlineStyle(palette: palette))
        }
        .padding(20)
        .frame(width: 430)
        .background(palette.chrome)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            state.setRoot(url)
        }
    }
}
