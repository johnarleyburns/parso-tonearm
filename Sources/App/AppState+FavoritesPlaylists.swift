import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore
#if !os(macOS)
import UIKit
#endif

extension AppState {
    // MARK: - Favorites (TF7)

    func isFavorite(_ row: TrackRow) -> Bool {
        favoriteIds.contains(row.id)
    }

    func toggleFavorite(_ row: TrackRow) async {
        let makeFavorite = !favoriteIds.contains(row.id)
        try? await store.setFavorite(trackId: row.id, makeFavorite)
        if makeFavorite { favoriteIds.insert(row.id) } else { favoriteIds.remove(row.id) }
        favoriteRows = (try? await store.favoriteRows()) ?? favoriteRows
    }

    // MARK: - Playlists (TF6)

    @discardableResult
    func createPlaylist(title: String, trackIds: [Int64], switchesTab: Bool = true) async -> Playlist? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let playlist = try? await store.createManualPlaylist(title: name, trackIds: trackIds)
        if let playlist {
            playlists.append(playlist)
            playlists.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            WidgetSnapshotPublisher.publish(appState: self, player: AudioPlayer.shared)
        }
        if switchesTab { tab = .myMusic }
        return playlist
    }

    @discardableResult
    func makePlaylist(title: String) async -> Playlist? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let created = try? await store.createManualPlaylist(title: name, trackIds: [])
        if let created {
            playlists.append(created)
            playlists.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            WidgetSnapshotPublisher.publish(appState: self, player: AudioPlayer.shared)
        }
        return created
    }

    func addToPlaylist(_ row: TrackRow, playlist: Playlist) async {
        guard let playlistID = playlist.id else { return }
        do {
            try await store.addToPlaylist(playlistId: playlistID, trackId: row.id)
        } catch {
            AppLogger.app.error("Adding track (row.id, privacy: .public) to playlist \(playlistID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Adding a playlist item does not change the catalog projections. A
        // full reload here can keep the sheet alive while SwiftUI rebuilds
        // every library row, and it can race playlist-detail reconciliation.
        // The detail view reloads its own items after the write completes.
        WidgetSnapshotPublisher.publish(appState: self, player: AudioPlayer.shared)
    }

    func deletePlaylist(_ playlist: Playlist) async {
        guard let id = playlist.id else { return }
        let originalPlaylists = playlists

        // Remove the row before the database write so the list cannot keep a
        // stale SwiftUI row alive while the async mutation is in flight. If
        // persistence fails, restore the exact previous ordering below.
        playlists.removeAll { $0.id == id }
        do {
            try await store.deletePlaylist(id: id)
        } catch {
            playlists = originalPlaylists
            AppLogger.app.error("Deleting playlist \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // A playlist mutation does not change tracks, sources, history, or
        // favorites. Updating only this collection avoids the old full
        // catalog reload racing SwiftUI's List reconciliation with each
        // playlist row's lazy track lookup (the path captured in the field
        // crash report).
        WidgetSnapshotPublisher.publish(appState: self, player: AudioPlayer.shared)
    }

}
