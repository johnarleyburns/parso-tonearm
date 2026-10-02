import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore
import TonearmDiscovery

/// Three root tabs — Playlists/Library unify into My Music and Sources moves
/// under Settings. Mixes are entered from Listen and playlist actions.
enum AppTab: Int, CaseIterable {
    case listen, myMusic, settings
}

enum PendingImport: Equatable {
    case folder, files, smbFolder
}

struct MixBuilderRequest: Identifiable {
    let id = UUID()
    let rows: [TrackRow]
    let lockedFirst: Int64?
    let sourcePlaylist: Playlist?

    init(rows: [TrackRow], lockedFirst: Int64?, sourcePlaylist: Playlist? = nil) {
        self.rows = rows
        self.lockedFirst = lockedFirst
        self.sourcePlaylist = sourcePlaylist
    }
}

@MainActor
final class AppState: ObservableObject {
    let store: LibraryStore
    /// One preparation coordinator shared by Settings, Up Next and Mix
    /// Preview. Its published state is the status surface for every action.
    let transitionPrepService: TransitionPrepService

    /// Restored from the last launch (real report: "when I enter Platterhead it doesn't return to
    /// where I was, it starts from scratch" — the tab always reset to `.listen`, nothing persisted
    /// it). The playback queue/position already survive relaunch
    /// (`AudioPlayer.restorePersistedQueue()`); this is the matching fix for which *screen* comes
    /// back. Not `@AppStorage` directly on the property (that requires a property-wrapper-only
    /// declaration) — a plain `UserDefaults` round-trip in `didSet`/`init` instead, so `tab` stays
    /// an ordinary `@Published` property everything else already binds to.
    @Published var tab: AppTab = .listen {
        didSet {
            guard tab != oldValue else { return }
            UserDefaults.standard.set(tab.rawValue, forKey: Self.lastTabKey)
        }
    }
    // v5: DJ removed for good (award-and-mix-plan.md); four tabs → three.
    // The versioned key prevents an old stored DJ raw value from reopening a
    // different surface after the removal.
    private static let lastTabKey = "lastActiveTab.v5"
    @Published var sources: [Source] = []
    @Published var playlists: [Playlist] = []
    @Published var allTracks: [TrackRow] = []
    /// Real report: "My Music says I have no music, then a few seconds
    /// later loads it all in" — `allTracks` starts empty and `LibraryView`
    /// had no way to tell "still loading" apart from "genuinely empty," so
    /// it showed the empty state first every launch. `false` until the
    /// first `reload()` completes (success or failure — an error still
    /// means the load attempt is over, not "still loading forever").
    @Published var didLoadLibraryOnce = false
    @Published var recentlyPlayed: [TrackRow] = []
    @Published var recentlyAdded: [TrackRow] = []
    @Published var favoriteRows: [TrackRow] = []
    @Published var favoriteIds: Set<Int64> = []
    @Published var listeningStats: ListeningStats.Summary = .empty
    @Published var searchText: String = ""
    @Published var searchResults: [TrackRow] = []
    /// Shared musical metadata for My Music and the DJ load browser.  This is
    /// refreshed from the same persisted discovery/DJ-prep records after a
    /// catalog reload, so existing and newly onboarded tracks get BPM and key
    /// without requiring the user to open DJ first.
    @Published private(set) var musicalInfo: [Int64: DJLoadTrackInfo] = [:]
    /// Bumps when BPM/key metadata changes so large My Music renders can be
    /// recomputed off the main actor without comparing the whole dictionary.
    @Published private(set) var musicalInfoRevision = 0
    /// Monotonic catalog/search revision. Views use this scalar as their
    /// render key instead of hashing or mapping the full track array in body.
    @Published private(set) var libraryRevision = 0
    @Published var showAddMenu = false
    @Published var showNowPlaying = false
    @Published var showAddSource = false
    @Published var showAddRemoteLibrary = false
    @Published var showCreatePlaylist = false
    @Published var mixBuilderRequest: MixBuilderRequest?
    /// Set by a Top Artist row's tap on the Listen tab (docs/plans/mood-
    /// based-listening-plan.md §3.5): the artist name to land on. Consumed
    /// once by `MyMusicView` on appear (switches to the Artists scope,
    /// resolves the name to a `LibraryBrowse.Entry`, pushes it onto the
    /// bound navigation path), then cleared — same one-shot launch-intent
    /// pattern used elsewhere in this file.
    @Published var pendingArtistFilter: String?
    @Published internal(set) var downloadRevision = 0
    @Published internal(set) var activePhoneDownloads: Set<Int64> = []
    /// The row (not just id) whose "Change Artwork" picker is open — a remote
    /// row's id can still be transient/negative here, so the picker's
    /// `onChange` must persist it before assigning artwork.
    @Published var artworkChangeTrackRow: TrackRow?
    /// The row whose title/artist edit sheet is open (real report: an
    /// imported file's own embedded tags were wrong, with no way to fix it
    /// short of re-tagging the file outside the app).
    @Published var metadataEditTrackRow: TrackRow?
    @Published var offlineProgress: OfflineProgress?
    @Published var offlineSourceID: Int64?
    @Published var backgroundTitle: String?
    @Published var backgroundDone = false
    @Published var backgroundFailed = false
    @Published var pickedFolder: URL?
    @Published var pickedFolderBookmark: Data?
    @Published var pendingImport: PendingImport?
    // Watch
    @Published var watchSessionState: WatchSessionDisplayState = .unsupported
    @Published var showWatchSettings = false
    @Published var watchTransferActiveCount: Int = 0
    /// Watch track IDs (`PhoneWatchID` stable strings) the watch has reported as installed.
    @Published var watchInstalledTrackIDs: Set<String> = []
    /// Watch download job state keyed by the same stable string ID.
    @Published var watchJobStates: [String: String] = [:]
    @Published var watchInstalledBytes: Int64 = 0
    @Published var watchFailedCount: Int = 0
    /// Phase 8: the full Settings › Apple Watch projection (P1–P5).
    @Published var watchManagement = PhoneWatchManagementPresenter.Snapshot.empty
    // Settings-backed values
    @AppStorage("streamOnCellular") var streamOnCellular = true
    @AppStorage("preferFLAC") var preferFLAC = false
    @AppStorage("prefetchDepth") var prefetchDepth = 2
    @AppStorage("artworkLookup") var artworkLookup = true
    @AppStorage("didOnboard") var didOnboard = false
    /// "Keep Playing" (main-library queue continuation, C01–C09 CLAP reuse):
    /// on by default. Settings-level detail lives alongside `keepPlayingBatchSize`;
    /// the primary discoverable toggle is in Now Playing (CLAUDE.md "no silent/
    /// magic background work" — a settings-only toggle isn't sufficient).
    @AppStorage("keepPlayingEnabled") var keepPlayingEnabled = true
    @AppStorage("keepPlayingBatchSize") var keepPlayingBatchSize = 15
    @AppStorage("keepPlayingMatchingTracksOnly") var keepPlayingMatchingTracksOnly = true

    // The following are declared here (rather than in AppState+Watch.swift,
    // where they are used) because Swift extensions cannot hold stored
    // instance properties. `watchRuntime` is also used by `bootstrap()`
    // below and by AppState+CustomArtwork.swift. The product ships on iPhone
    // with an Apple Watch companion.
    var tickTask: Task<Void, Never>?
    lazy var watchRuntime = PhoneWatchRuntime(store: store, player: AudioPlayer.shared)

    private var musicalInfoObserver: NSObjectProtocol?

    init(store: LibraryStore = .shared) {
        self.store = store
        self.transitionPrepService = TransitionPrepService()
        if let saved = UserDefaults.standard.object(forKey: Self.lastTabKey) as? Int,
            let restored = AppTab(rawValue: saved)
        {
            tab = restored
        }
        musicalInfoObserver = NotificationCenter.default.addObserver(
            forName: .tonearmMusicalMetadataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshMusicalInfo()
            }
        }
    }

    func bootstrap() async {
        await fixLegacySourceTitles()
        await repairDuplicatePlaylistsOnce()
        // Before DiscoveryRuntimeController.startAfterBootstrap() (called
        // right after this returns, from TonearmApp) runs its launch
        // reconciliation sweep — these need to be real rows already, so
        // they're queued for indexing on the very first pass rather than
        // waiting for a later one.
        await seedBuiltInLibraryContentIfNeeded()
        await seedBuiltInMoodIndexIfNeeded()
        await ArtworkService.shared.migrateCacheIfNeeded()
        applySettingsToPlayer()
        await AudioPlayer.shared.restorePersistedQueue()
        await reload()
        if UserDefaults.standard.object(forKey: "smartTransitionsEnabled") as? Bool ?? true {
            transitionPrepService.prepare(rows: AudioPlayer.shared.queue, appState: self,
                                          allowsCellular: AudioPlayer.shared.isPlayingMix)
        }
        await AudioCache.shared.garbageCollectStalePartials()
        Task { await warmLocalSourceArtwork() }
        watchRuntime.onChange = { [weak self] in self?.refreshWatchStateFromRuntime() }
        await watchRuntime.activate()
        startWatchTransferTick()
    }

    private func repairDuplicatePlaylistsOnce() async {
        let key = "repair.playlistDedup.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        _ = try? await store.mergeDuplicateFolderPlaylists()
        _ = try? await store.removeDuplicatePlaylistItems()
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Resolves and caches a representative cover for local sources that don't yet
    /// have one remembered, so app-update installs pick up embedded artwork without
    /// waiting for each tile to appear. Runs off the launch critical path.
    private func warmLocalSourceArtwork() async {
        let locals = sources.filter { $0.kind == .local && $0.artworkTrackId == nil }
        guard !locals.isEmpty else { return }
        for source in locals {
            _ = await resolvedArtwork(for: source)
        }
        // Pick up the persisted artworkTrackId values so tiles use the remembered
        // pick directly instead of rescanning.
        await reload()
    }

    /// One-time repair for sources saved before the list/collection naming fix:
    /// re-derive human-readable titles from the stored originalURL slug.
    func fixLegacySourceTitles() async {
        guard let existing = try? await store.allSources() else { return }
        for source in existing {
            guard let id = source.id else { continue }
            var newTitle: String?

            switch source.kind {
            case .iaList:
                if let raw = source.originalURL,
                   case .list(_, _, let slug)? = try? URLGrammar.parse(raw).get(),
                   let slug, !slug.isEmpty {
                    newTitle = SourceService.prettify(slug)
                }
            case .iaCollection:
                // Buggy rows stored the raw identifier as the title.
                if let idf = source.iaIdentifier, source.title == idf {
                    newTitle = SourceService.prettify(idf)
                }
            default:
                break
            }

            if let newTitle, !newTitle.isEmpty, newTitle != source.title {
                try? await store.updateSourceTitle(id: id, title: newTitle)
            }
        }
    }

    func applySettingsToPlayer() {
        AudioPlayer.shared.streamOnCellular = streamOnCellular
        AudioPlayer.shared.prefetchDepth = PrefetchDepthPolicy.clamp(prefetchDepth)
        AudioPlayer.shared.preferFLAC = preferFLAC
        AudioPlayer.shared.keepPlayingEnabled = keepPlayingEnabled
        AudioPlayer.shared.keepPlayingBatchSize = min(30, max(5, keepPlayingBatchSize))
        AudioPlayer.shared.keepPlayingMatchingTracksOnly = keepPlayingMatchingTracksOnly
        AudioPlayer.shared.smartTransitionsEnabled =
            UserDefaults.standard.object(forKey: "smartTransitionsEnabled") as? Bool ?? true
        let lookup = artworkLookup
        Task { await ArtworkService.shared.setArtworkLookupEnabled(lookup) }
    }

    func reload() async {
        do {
            let loadedSources = try await store.allSources()
            let loadedPlaylists = try await store.allPlaylists()
            let loadedTracks = try await store.allTrackRows()
            let loadedRecentlyPlayed = try await store.recentlyPlayedRows()
            let loadedRecentlyAdded = try await store.recentlyAddedRows()
            let loadedFavoriteRows = try await store.favoriteRows()
            let loadedFavoriteIds = try await store.favoriteTrackIds()
            let playEvents = try await store.allPlayEvents()

            sources = loadedSources
            playlists = loadedPlaylists
            allTracks = loadedTracks
            libraryRevision &+= 1
            musicalInfo = (try? await store.djLoadTrackInfo(trackIds: loadedTracks.map(\.id))) ?? [:]
            musicalInfoRevision &+= 1
            recentlyPlayed = loadedRecentlyPlayed
            recentlyAdded = loadedRecentlyAdded
            favoriteRows = loadedFavoriteRows
            favoriteIds = loadedFavoriteIds
            let stats = await Task.detached(priority: .utility) {
                ListeningStats.summarize(events: playEvents, tracks: loadedTracks, rankLimit: 10)
            }.value
            listeningStats = stats
            WidgetSnapshotPublisher.publish(appState: self, player: AudioPlayer.shared)
        } catch {
            AppLogger.app.error("Reload failed: \(error.localizedDescription, privacy: .public)")
        }
        didLoadLibraryOnce = true
    }

    /// Refresh only the derived BPM/key projection after the discovery worker
    /// commits a completed analysis. A full catalog reload here would rebuild
    /// every library array and make My Music visibly stutter on large catalogs.
    func refreshMusicalInfo() async {
        let ids = allTracks.map(\.id)
        guard !ids.isEmpty else {
            if !musicalInfo.isEmpty { musicalInfo = [:] }
            musicalInfoRevision &+= 1
            return
        }
        guard let updated = try? await store.djLoadTrackInfo(trackIds: ids),
              updated != musicalInfo else { return }
        musicalInfo = updated
        musicalInfoRevision &+= 1
    }

    func runSearch() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        searchResults = (try? await store.search(searchText)) ?? []
        libraryRevision &+= 1
    }

    func tracks(for source: Source) async -> [TrackRow] {
        guard let id = source.id else { return [] }
        return (try? await store.tracks(forSource: id)) ?? []
    }
}

extension Notification.Name {
    static let tonearmMusicalMetadataDidChange = Notification.Name(
        "tonearm.musicalMetadataDidChange")
}
