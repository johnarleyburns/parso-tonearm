import Foundation
import SwiftUI

enum AppTab: Int, CaseIterable {
    case library, playlists, sources, settings
}

@MainActor
final class AppState: ObservableObject {
    let store: LibraryStore

    @Published var tab: AppTab = .library
    @Published var sources: [Source] = []
    @Published var playlists: [Playlist] = []
    @Published var allTracks: [TrackRow] = []
    @Published var searchText: String = ""
    @Published var searchResults: [TrackRow] = []
    @Published var showAddMenu = false
    @Published var showNowPlaying = false
    @Published var showAddSource = false
    @Published var showFolderImporter = false
    @Published var showFileImporter = false
    @Published var pickedFolder: URL?
    // Settings-backed values
    @AppStorage("streamOnCellular") var streamOnCellular = true
    @AppStorage("preferFLAC") var preferFLAC = true
    @AppStorage("prefetchDepth") var prefetchDepth = 2

    init(store: LibraryStore = .shared) {
        self.store = store
    }

    func bootstrap() async {
        await reload()
        if sources.isEmpty && playlists.isEmpty {
            await SampleData.seed(into: store)
            await reload()
        }
        applySettingsToPlayer()
        await CacheStore.shared.garbageCollectStalePartials()
    }

    func applySettingsToPlayer() {
        AudioPlayer.shared.streamOnCellular = streamOnCellular
        AudioPlayer.shared.prefetchDepth = prefetchDepth
    }

    func reload() async {
        do {
            sources = try await store.allSources()
            playlists = try await store.allPlaylists()
            allTracks = try await store.allTrackRows()
        } catch {
            print("reload error: \(error)")
        }
    }

    func runSearch() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        searchResults = (try? await store.search(searchText)) ?? []
    }

    func tracks(for source: Source) async -> [TrackRow] {
        guard let id = source.id else { return [] }
        return (try? await store.tracks(forSource: id)) ?? []
    }

    func deleteSource(_ source: Source) async {
        guard let id = source.id else { return }
        try? await store.deleteSource(id: id)
        await reload()
    }

    func playSource(_ source: Source, startAt: Int = 0) async {
        let tracks = await tracks(for: source)
        guard !tracks.isEmpty else { return }
        AudioPlayer.shared.play(tracks: tracks, startAt: startAt)
    }
}
