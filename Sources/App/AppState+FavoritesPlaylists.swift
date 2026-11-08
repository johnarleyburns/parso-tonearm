import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore
import UIKit

extension AppState {
    // MARK: - Favorites (TF7)

    func isFavorite(_ row: TrackRow) -> Bool {
        favoriteIds.contains(row.id)
    }

    /// Real report: favoriting a track played straight from browsing a cloud-drive source (never
    /// imported/added to the library first) silently never showed up in Favorites, nor in Jump
    /// Back In for the same reason. Root cause: a browsed-but-not-yet-imported remote row carries
    /// a transient, negative `id` (`RemoteTrackRowFactory`) that never exists in the `track`
    /// table — writing `favorite`/`play_history` rows against it violates their foreign key and
    /// throws, which `try?` swallowed with no user-visible sign anything had failed. Persist the
    /// row first, exactly like `assignCustomArtwork(toTrack:)` already does for the same reason.
    func toggleFavorite(_ row: TrackRow) async {
        var target = row
        if target.id < 0 {
            guard let persisted = await persistRemoteTrack(target) else { return }
            target = persisted
        }
        let makeFavorite = !favoriteIds.contains(target.id)
        do {
            try await store.setFavorite(trackId: target.id, makeFavorite)
        } catch {
            return
        }
        if makeFavorite { favoriteIds.insert(target.id) } else { favoriteIds.remove(target.id) }
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
