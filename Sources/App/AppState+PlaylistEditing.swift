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
        try? await store.renamePlaylist(id: id, title: name)
        await reload()
    }

    func reorderPlaylist(_ playlist: Playlist, from source: Int, to destination: Int) async {
        guard let id = playlist.id else { return }
        try? await store.reorderPlaylist(id: id, from: source, to: destination)
    }

    func reorderPlaylist(_ playlist: Playlist, fromOffsets offsets: IndexSet, toOffset destination: Int) async {
        guard let id = playlist.id else { return }
        try? await store.reorderPlaylist(id: id, fromOffsets: offsets, toOffset: destination)
    }

    func removeFromPlaylist(_ playlist: Playlist, atOffsets offsets: IndexSet) async {
        guard let id = playlist.id else { return }
        try? await store.removeFromPlaylist(playlistId: id, atOffsets: offsets)
    }
}
