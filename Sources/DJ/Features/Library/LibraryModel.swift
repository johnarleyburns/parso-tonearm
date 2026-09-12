import Foundation
import Combine
import TonearmCore

/// A folder import's outcome — was `DJLibraryStore.importFolder`'s return
/// type before C02 retired that duplicate-catalog writer; kept here as
/// `LibraryModel.importFolder`'s own result shape (built from the core
/// `IngestService.addFolder` call) so `LibraryView`'s "Import finished"
/// alert needs no change.
public struct ImportSummary: Sendable, Equatable {
    public let added: Int
    public let updated: Int
    public let skipped: Int
    public let failed: [URL]

    public init(added: Int = 0, updated: Int = 0, skipped: Int = 0, failed: [URL] = []) {
        self.added = added
        self.updated = updated
        self.skipped = skipped
        self.failed = failed
    }
}

/// View model for the Library screen (§41.2). C02 (IMPLEMENT_CLAP_PLAN.md):
/// re-pointed at the one core `LibraryStore` database instead of the
/// separate DJ database's `DJTrackRepository`/`LibraryQuery`. Core
/// `LibraryStore` has no live-observation API (confirmed by session 13's
/// audit — no `observe`/`AsyncStream`/`ValueObservation` symbol on it), so
/// this is now **pull-based**, mirroring the non-DJ `Sources/Features/
/// Library/LibraryView.swift`'s `AppState.reload()` pattern: `refresh()` is
/// called once on `start()` and again after a folder import completes,
/// instead of a live subscription that pushed on every external database
/// change. This is an honest behavior change (loses live-update-on-
/// external-change), not a pure call-site rename.
///
/// The view still renders `DJTrackRow` (no UI change) — `refresh()` builds
/// that row shape from the core `TrackRow` + `DiscoveryTrackAnalysis`
/// instead of the DJ database's own flat listing query.
@MainActor
public final class LibraryModel: ObservableObject {
    @Published public private(set) var rows: [DJTrackRow] = []
    @Published public var searchText: String = ""
    @Published public private(set) var isImporting = false
    @Published public private(set) var lastImport: ImportSummary?
    @Published public private(set) var importError: String?

    /// The one core music catalog (plan §3).
    public let library: LibraryStore
    /// DJ-local operational data (crates, hardware, etc.) that other Library-
    /// screen entry points (Vibe Search, auto-playlists) still read via their
    /// own assemblies — retained here only so those call sites keep working
    /// unchanged until they are independently rewired (see
    /// IMPLEMENTATION_STATUS.md's Slice B tracking).
    public let store: DJLibraryStore

    public init(library: LibraryStore = .shared, store: DJLibraryStore = .shared) {
        self.library = library
        self.store = store
    }

    /// Client-side literal filter on top of the pulled rows.
    public var filteredRows: [DJTrackRow] {
        guard !searchText.isEmpty else { return rows }
        return rows.filter { row in
            row.title.localizedCaseInsensitiveContains(searchText)
                || row.artistNames.localizedCaseInsensitiveContains(searchText)
                || (row.albumTitle?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    /// Pulls the current core library once. Call again after anything that
    /// could have changed it (an import completing) — there is no live push.
    public func start() {
        Task { [weak self] in await self?.refresh() }
    }

    /// No-op: kept so the view's `.task { model.start() } .onDisappear {
    /// model.stop() }` pairing (mirroring the DJ workspace's lifecycle idiom)
    /// still compiles unchanged. There is no subscription to cancel now.
    public func stop() {}

    /// Re-reads the core library and rebuilds `rows` from it.
    public func refresh() async {
        let coreRows = (try? await library.allTrackRows()) ?? []
        var built: [DJTrackRow] = []
        built.reserveCapacity(coreRows.count)
        for row in coreRows {
            let analysis: DiscoveryTrackAnalysis? = (try? await library.dbQueue.read { db in
                try DiscoveryTrackAnalysis.fetchOne(db, key: row.id)
            }) ?? nil
            built.append(DJTrackRow(
                id: row.id,
                title: row.track.title,
                artistNames: row.artist?.name ?? row.album?.artist ?? "",
                albumTitle: row.album?.title,
                durationSec: row.track.durationSec,
                bpm: analysis?.bpm,
                camelot: analysis?.key,
                energy: analysis?.energy,
                analysisState: analysis?.completedAt != nil ? "analyzed" : "pending",
                stemState: "none"))
        }
        rows = built
    }

    /// Imports a folder through the SAME core import path the non-DJ Library
    /// screen uses (`IngestService.addFolder(...into: LibraryStore)`) instead
    /// of the DJ-local `DJLibraryStore.importFolder` — one library, one
    /// writer, no duplicate catalog (C02).
    public func importFolder(_ url: URL) async {
        isImporting = true
        importError = nil
        defer { isImporting = false }
        let before = rows.count
        do {
            try await IngestService().addFolder(url, includeSubfolders: true,
                                                keepOrder: true, watch: false,
                                                into: library)
            await refresh()
            let added = max(0, rows.count - before)
            lastImport = ImportSummary(added: added, updated: 0, skipped: 0, failed: [])
        } catch {
            importError = error.localizedDescription
        }
    }
}
