import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore
#if !os(macOS)
import UIKit
#endif

/// Five root tabs — Playlists/Library unify into My Music,
/// Sources moves under Settings. See
/// docs/plans/UNIFIED_TONEARM_MY_MUSIC_TRANSITION_LAB_HANDOFF.md.
enum AppTab: Int, CaseIterable {
    case listen, myMusic, dj, settings
}

enum PendingImport: Equatable {
    case folder, files, smbFolder
}

@MainActor
final class AppState: ObservableObject {
    let store: LibraryStore

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
    // v2: AppTab's cases/raw-values changed (six tabs -> four) — a stale v1
    // integer must never be reinterpreted under the new enum (e.g. old
    // `.sources` == 3 must not silently resolve to new `.settings` == 3).
    // v3: DJ/Transition Lab removed (four tabs -> three) — old `.settings`
    // == 3 must not silently resolve to a now out-of-range/wrong case.
    // v4: the real DJ surface is back as a first-class tab immediately before
    // Settings; reset the persisted raw value rather than reopening Settings
    // as DJ on an upgrade.
    private static let lastTabKey = "lastActiveTab.v4"
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
    /// True while a full-screen performance surface owns the display (§42.6,
    /// §42.7a). The DJ decks put the crossfader on the true bottom edge and the
    /// spec is explicit that it is always visible and never occluded — but the
    /// app's dock (mini player + tabs) is a root-level overlay, so it sat on top
    /// of the crossfader, REC and Crate, and a tap on any of them reached the
    /// dock instead. The surface raises this while it is on screen.
    @Published var isPerformanceSurfaceFullScreen = false
    @Published var showAddMenu = false
    @Published var showNowPlaying = false
    @Published var showAddSource = false
    @Published var showAddRemoteLibrary = false
    @Published var showCreatePlaylist = false
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
    // below and by AppState+CustomArtwork.swift. Not compiled on macOS: no
    // paired watch reachable from a Mac (native Mac app,
    // docs/plans/native-mac-app-plan.md §1 — no Watch extension embed).
    #if !os(macOS)
    var tickTask: Task<Void, Never>?
    lazy var watchRuntime = PhoneWatchRuntime(store: store, player: AudioPlayer.shared)
    #endif

    init(store: LibraryStore = .shared) {
        self.store = store
        if let saved = UserDefaults.standard.object(forKey: Self.lastTabKey) as? Int,
            let restored = AppTab(rawValue: saved)
        {
            tab = restored
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
        await AudioCache.shared.garbageCollectStalePartials()
        Task { await warmLocalSourceArtwork() }
        #if !os(macOS)
        watchRuntime.onChange = { [weak self] in self?.refreshWatchStateFromRuntime() }
        await watchRuntime.activate()
        startWatchTransferTick()
        #endif
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
            recentlyPlayed = loadedRecentlyPlayed
            recentlyAdded = loadedRecentlyAdded
            favoriteRows = loadedFavoriteRows
            favoriteIds = loadedFavoriteIds
            listeningStats = ListeningStats.summarize(events: playEvents, tracks: loadedTracks, rankLimit: 10)
            WidgetSnapshotPublisher.publish(appState: self, player: AudioPlayer.shared)
        } catch {
            print("reload error: \(error)")
        }
        didLoadLibraryOnce = true
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
}
