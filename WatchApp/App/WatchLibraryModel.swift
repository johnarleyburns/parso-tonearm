import Foundation
import Combine
import WatchKit
import TonearmWatchCore
import TonearmWatchProtocol

/// A derived album grouping. Albums are not a stored collection on the watch — they are projected
/// from catalog tracks carrying the same album title. Readiness is shown separately so metadata can
/// be searched before its audio is downloaded.
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
    /// Sender-side byte progress for tracks the phone is transferring right now, keyed by raw track
    /// ID. Drives the Now Playing download ring; empty when nothing is in flight.
    @Published private(set) var transferFractions: [String: Double] = [:]
    /// The phone's latest download status (watch redesign D1): per-root progress and the specific
    /// reason anything is waiting. `nil` until the phone first reports.
    @Published private(set) var downloadStatus: WatchDownloadStatusSnapshot?

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

    func search(query: String, onWatchOnly: Bool) async -> [WatchResultRow] {
        guard let repository else { return [] }
        let tracks = (try? await repository.tracks(readyOnly: false)) ?? []
        let playlists = (try? await repository.playlists()) ?? []
        return WatchLocalCatalogSearch.rows(query: query, tracks: tracks, playlists: playlists,
                                            onWatchOnly: onWatchOnly)
    }

    func refresh() async {
        guard let repository else { return }
        let loadedTracks = (try? await repository.tracks(readyOnly: false)) ?? []
        let loadedPlaylists = (try? await repository.playlists()) ?? []
        let loadedStorage = try? await repository.storage()
        tracks = loadedTracks
        playlists = loadedPlaylists
        storage = loadedStorage
    }

    func setPhoneReachable(_ reachable: Bool) { phoneReachable = reachable }

    func setTransferFractions(_ fractions: [String: Double]) { transferFractions = fractions }

    func setDownloadStatus(_ status: WatchDownloadStatusSnapshot) {
        // §3 haptics: `.success` once when a download finishes.
        let wasIncomplete = Set((downloadStatus?.roots ?? []).filter { $0.state != .complete }.map(\.rootID))
        let ready = Set(tracks.filter(\.isReady).map(\.id))
        let nowComplete = status.roots.map { $0.reconciled(readyTrackIDs: ready) }
            .filter { $0.state == .complete && wasIncomplete.contains($0.rootID) }
        if !nowComplete.isEmpty { WKInterfaceDevice.current().play(.success) }
        downloadStatus = status
        transferFractions = Dictionary(uniqueKeysWithValues:
            status.activeTransfers.map { ($0.trackID.rawValue, $0.fractionComplete) })
    }

    /// Roots still in progress, newest activity first (D1 "Downloading" section).
    var activeDownloadRoots: [WatchDownloadRootStatus] {
        let ready = Set(tracks.filter(\.isReady).map(\.id))
        return (downloadStatus?.roots ?? []).map { $0.reconciled(readyTrackIDs: ready) }.filter { $0.state != .complete }
    }

    /// Byte progress for one track, or `nil` when the phone isn't transferring it.
    func transferFraction(forTrackID id: String) -> Double? { transferFractions[id] }
}
