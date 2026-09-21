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

    func createPlaylist(title: String, trackIds: [Int64], switchesTab: Bool = true) async {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        _ = try? await store.createManualPlaylist(title: name, trackIds: trackIds)
        await reload()
        if switchesTab { tab = .myMusic }
    }

    @discardableResult
    func makePlaylist(title: String) async -> Playlist? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let created = try? await store.createManualPlaylist(title: name, trackIds: [])
        await reload()
        return created
    }

    func addToPlaylist(_ row: TrackRow, playlist: Playlist) async {
        guard let playlistID = playlist.id else { return }
        try? await store.addToPlaylist(playlistId: playlistID, trackId: row.id)
        await reload()
    }

    func deletePlaylist(_ playlist: Playlist) async {
        guard let id = playlist.id else { return }
        try? await store.deletePlaylist(id: id)
        await reload()
    }

}
