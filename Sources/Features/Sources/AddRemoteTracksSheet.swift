import SwiftUI
import TonearmCore

struct AddRemoteTracksSheet: View {
    let source: Source
    let nodes: [RemoteNode]
    let scopeTitle: String
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var count = 1
    @State private var playlistID: Int64 = -1
    @State private var playlistName = ""
    @State private var done = 0
    @State private var isAdding = false
    @State private var cancelled = false
    @State private var resultText: String?

    private var available: Int { nodes.count }

    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(Color.white.opacity(0.35)).frame(width: 36, height: 5)
            Text("Add tracks to playlist").font(.headline)
            Text(scopeTitle).font(.caption).foregroundStyle(Palette.ink3)
            Stepper("Add \(count) of \(available) tracks", value: $count,
                    in: 1...max(1, available))
                .accessibilityIdentifier("remoteAdd.count")
            if available > 1 {
                Slider(value: Binding(get: { Double(count) }, set: { count = Int($0.rounded()) }),
                       in: 1...Double(available), step: 1)
                    .accessibilityIdentifier("remoteAdd.slider")
            }
            Picker("Playlist", selection: $playlistID) {
                ForEach(appState.playlists) { playlist in
                    Text(playlist.title).tag(playlist.id ?? -2)
                }
                Text("Create a new playlist…").tag(Int64(-1))
            }.pickerStyle(.menu).accessibilityIdentifier("remoteAdd.playlist")
            if playlistID == -1 {
                TextField("Playlist name", text: $playlistName).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("remoteAdd.name")
            }
            if isAdding { ProgressView("Adding \(done) of \(count)…", value: Double(done), total: Double(count)) }
            if let resultText {
                Text(resultText).font(.caption).foregroundStyle(Palette.ink2)
                    .accessibilityIdentifier("remoteAdd.result")
            }
            Spacer()
            HStack {
                Button(isAdding ? "Cancel" : "Close") {
                    if isAdding { cancelled = true } else { dismiss() }
                }
                Spacer()
                Button("Add") { Task { await add() } }
                    .disabled(isAdding || available == 0 || (playlistID == -1 && playlistName.trimmingCharacters(in: .whitespaces).isEmpty))
                    .accessibilityIdentifier("remoteAdd.confirm")
            }
        }
        .padding(20).foregroundStyle(Palette.ink)
        .presentationDetents([.large]).presentationBackground(.ultraThinMaterial)
    }

    private func add() async {
        isAdding = true; cancelled = false; done = 0; resultText = nil
        defer { isAdding = false }
        let playlist: Playlist?
        if playlistID == -1 { playlist = await appState.makePlaylist(title: playlistName) }
        else { playlist = appState.playlists.first { $0.id == playlistID } }
        guard let playlist, let playlistID = playlist.id else { return }
        let provider: any RemoteLibraryProvider
        do { provider = try RemoteLibraryProviderFactory.provider(for: source) }
        catch { resultText = error.localizedDescription; return }

        var added = 0
        var failed = 0
        for node in nodes.prefix(count) {
            guard !cancelled else { break }
            let persisted = await RemotePlaylistIngest.persist(
                nodes: [node], resolve: { try await provider.resolve(node: $0) },
                source: source, store: appState.store)
            if let trackID = persisted.trackIDs.first,
               let row = try? await appState.store.tracks(forSource: source.id ?? -1).first(where: { $0.id == trackID }) {
                try? await appState.store.addToPlaylist(playlistId: playlistID, trackId: trackID)
                // Resolve once more to retain transient authorization headers for the pinning fetch.
                if let transient = try? await appState.remoteTrackRows(source: source, nodes: [node]).first {
                    _ = await appState.download(rows: [transient])
                } else {
                    _ = await appState.download(rows: [row])
                }
                added += 1
            } else { failed += max(1, persisted.skipped) }
            done += 1
        }
        await appState.reload()
        resultText = "\(added) added · \(failed) unavailable"
    }
}
