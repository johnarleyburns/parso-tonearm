import SwiftUI
import TonearmCore

struct AddToPlaylistDialog: View {
    enum Target: Equatable { case existing(Playlist), create(String) }
    let title: String
    let subtitle: String?
    let confirm: (Target) async -> Void
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int64 = -1
    @State private var name = ""

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 36, height: 5)
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Palette.ink3) }
            Picker("Playlist", selection: $selection) {
                ForEach(appState.playlists) { playlist in
                    Text(playlist.title).tag(playlist.id ?? -2)
                }
                Text("Create a new playlist…").tag(Int64(-1))
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("addToPlaylist.picker")
            if selection == -1 {
                TextField("Playlist name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("addToPlaylist.name")
            }
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add") {
                    Task {
                        if selection == -1 { await confirm(.create(name)) }
                        else if let playlist = appState.playlists.first(where: { $0.id == selection }) {
                            await confirm(.existing(playlist))
                        }
                        dismiss()
                    }
                }
                .disabled(selection == -1 && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("addToPlaylist.confirm")
            }
        }
        .padding(20).foregroundStyle(Palette.ink)
        .presentationDetents([.height(280)])
        .presentationBackground(.ultraThinMaterial)
    }
}
