import Foundation
import Combine
import TonearmWatchCore

/// A derived album grouping. Albums are not a stored collection on the watch — they are projected
/// from whatever ready tracks carry the same album title, so "only ready local tracks and derived
/// collections appear" (Phase 6 DoD) holds by construction.
struct WatchAlbumGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String?
    let trackIDs: [String]
}

/// The watch UI's single source of truth. Wraps `WatchLibraryRepository` and republishes its
/// `Sendable` snapshots on the main actor; `WatchSyncActor` calls `refresh()` after every change to
/// local truth (`onLibraryChanged`).
@MainActor
final class WatchLibraryModel: ObservableObject {
    @Published private(set) var tracks: [WatchTrackSnapshot] = []
    @Published private(set) var playlists: [WatchPlaylistSnapshot] = []
    @Published private(set) var storage: WatchStorageSnapshot?
    @Published private(set) var recoveryNotice: String?
    /// Live iPhone reachability, pushed by the connectivity coordinator's observer.
    @Published private(set) var phoneReachable = false

    private let repository: WatchLibraryRepository?

    init(repository: WatchLibraryRepository?, recoveryNotice: String? = nil) {
        self.repository = repository
        self.recoveryNotice = recoveryNotice
    }

    var albums: [WatchAlbumGroup] {
        let grouped = Dictionary(grouping: tracks.filter { !$0.albumTitle.isEmpty }, by: \.albumTitle)
        return grouped.map { title, rows in
            WatchAlbumGroup(
                id: title, title: title,
                artist: rows.first(where: { !$0.artist.isEmpty })?.artist,
                trackIDs: rows
                    .sorted { ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0) }
                    .map(\.id))
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func track(id: String) -> WatchTrackSnapshot? { tracks.first { $0.id == id } }
    func playlist(id: String) -> WatchPlaylistSnapshot? { playlists.first { $0.id == id } }
    func album(id: String) -> WatchAlbumGroup? { albums.first { $0.id == id } }

    /// Ready tracks for a playlist, in playlist order.
    func readyTracks(forPlaylist id: String) -> [WatchTrackSnapshot] {
        guard let playlist = playlist(id: id) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return playlist.readyTrackIDs.compactMap { byID[$0] }
    }

    func readyTracks(forAlbum id: String) -> [WatchTrackSnapshot] {
        guard let album = album(id: id) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        return album.trackIDs.compactMap { byID[$0] }
    }

    func refresh() async {
        guard let repository else { return }
        let loadedTracks = (try? await repository.tracks(readyOnly: true)) ?? []
        let loadedPlaylists = (try? await repository.playlists()) ?? []
        let loadedStorage = try? await repository.storage()
        tracks = loadedTracks
        // Only playlists with at least one ready track are shown offline — a playlist whose audio
        // has not arrived is not a browsable collection yet.
        playlists = loadedPlaylists.filter { !$0.readyTrackIDs.isEmpty }
        storage = loadedStorage
    }

    func setPhoneReachable(_ reachable: Bool) { phoneReachable = reachable }
}
