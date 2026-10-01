import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore
import UIKit

extension AppState {
    func renamePlaylist(_ playlist: Playlist, title: String) async {
        guard let id = playlist.id else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await store.renamePlaylist(id: id, title: name)
            // Playlist list mutations must not trigger a full catalog reload
            // while SwiftUI's List is reconciling its rows. The old reload
            // path is the stack captured in the field crash report.
            if let index = playlists.firstIndex(where: { $0.id == id }) {
                playlists[index].title = name
            }
            WidgetSnapshotPublisher.publish(appState: self, player: AudioPlayer.shared)
        } catch {
            AppLogger.app.error("Renaming playlist \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reorderPlaylist(_ playlist: Playlist, from source: Int, to destination: Int) async {
        guard let id = playlist.id else { return }
        try? await store.reorderPlaylist(id: id, from: source, to: destination)
    }

    func reorderPlaylist(_ playlist: Playlist, fromOffsets offsets: IndexSet, toOffset destination: Int) async {
        guard let id = playlist.id else { return }
        try? await store.reorderPlaylist(id: id, fromOffsets: offsets, toOffset: destination)
    }

    func sortPlaylistByBPM(_ playlist: Playlist) async {
        guard let id = playlist.id else { return }
        try? await store.sortPlaylistByBPM(id: id)
    }

    func removeFromPlaylist(_ playlist: Playlist, atOffsets offsets: IndexSet) async {
        guard let id = playlist.id else { return }
        try? await store.removeFromPlaylist(playlistId: id, atOffsets: offsets)
    }
}
