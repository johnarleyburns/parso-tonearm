#if !os(watchOS)
import Foundation
import TonearmCore
import TonearmWatchProtocol

/// The phone's Phase 6 watch runtime: the §5 protocol coordinator, its WCSession adapter, the §8
/// download manager, and the glue that keeps `AppState`'s watch surface (`downloadToWatch`,
/// `removeFromWatch`, the transfer badge, the session state) working on top of them.
///
/// Replaces the pre-cutover `PhoneWatchSessionAdapter` + `WatchTransferController` + full-catalog
/// export. `LibraryStore` is still the phone's library — that half never moved — but the watch is no
/// longer handed a mirror of it; it pulls what it needs over the typed protocol and installs only
/// the audio the phone's desired roots call for.
@MainActor
final class PhoneWatchRuntime {
    private let store: LibraryStore
    private let downloadStore: PhoneWatchDownloadStore
    private let coordinator: PhoneWatchProtocolCoordinator
    private let protocolAdapter: PhoneWatchProtocolAdapter
    private let downloadManager: PhoneWatchDownloadManager
    private let inbound: PhoneWatchInbound
    private let libraryID: WatchPairedLibraryID

    /// Fired on the main actor whenever watch-derived state changes, so `AppState` can republish.
    var onChange: (@MainActor @Sendable () -> Void)?

    private(set) var installedTrackIDs: Set<String> = []
    private(set) var installedBytes: Int64 = 0
    private(set) var activeJobCount = 0
    private(set) var failedJobCount = 0
    private(set) var jobStateByTrackID: [String: String] = [:]
    private(set) var connected = false

    init(store: LibraryStore, player: AudioPlayer) {
        self.store = store
        self.libraryID = Self.resolveLibraryID()

        let downloadStore = PhoneWatchDownloadStore(library: store)
        self.downloadStore = downloadStore

        let revisionStore = PhoneWatchDownloadRevisionAdapter(store: downloadStore)
        let inbound = PhoneWatchInbound()
        self.inbound = inbound

        let downloadedProvider: @Sendable () async -> Set<WatchTrackID> = { [weak downloadStore] in
            guard let downloadStore else { return [] }
            let ids = (try? await downloadStore.installedTrackIDs()) ?? []
            return Set(ids.map(WatchTrackID.init))
        }

        let playbackAdapter = PhoneWatchPlaybackAdapter(player: player,
                                                        downloadedProvider: downloadedProvider)

        let requestHandler = PhoneWatchRequestHandler(
            store: store,
            player: playbackAdapter,
            libraryID: libraryID,
            revisionStore: revisionStore,
            downloadedProvider: downloadedProvider,
            onManifest: { [inbound] payload in await inbound.manifest(payload) },
            onReconciliation: { [inbound] request in await inbound.reconciliation(request) })

        let coordinator = PhoneWatchProtocolCoordinator(
            transport: PhoneWatchProtocolAdapter.transport,
            handler: requestHandler,
            libraryID: libraryID,
            revisionStore: revisionStore)
        self.coordinator = coordinator
        self.protocolAdapter = PhoneWatchProtocolAdapter(endpoint: coordinator)

        let audioResolver = PhoneWatchLibraryAudioResolver(store: store)
        let fileTransfer = PhoneWatchSessionFileTransfer(
            transport: PhoneWatchProtocolAdapter.transport,
            phoneRevision: { [weak downloadStore] in (try? await downloadStore?.currentRevision()) ?? 0 })

        let rootExpander: @Sendable (PhoneWatchDownloadRoot) async -> [String] = { [weak store] root in
            guard root.kind == .playlist, let store else { return root.desiredTrackIDs }
            var pid = PhoneWatchID.playlistRowID(root.sourceID)
            if pid == nil {
                pid = (try? await store.localID(table: "playlist", syncID: root.sourceID)) ?? nil
            }
            guard let pid else { return root.desiredTrackIDs }
            let rows = (try? await store.playlistTrackRows(playlistId: pid)) ?? []
            return rows.map { PhoneWatchID.track($0.row.track).rawValue }
        }

        self.downloadManager = PhoneWatchDownloadManager(
            store: downloadStore,
            resolver: audioResolver,
            transfer: fileTransfer,
            emitRoots: { [weak coordinator] descriptors, _ in
                _ = await coordinator?.sendDownloadRoots(descriptors)
            },
            rootExpander: rootExpander)

        Task { await inbound.connect(self) }
    }

    // MARK: - Lifecycle

    func activate() async {
        protocolAdapter.activate()
        try? await downloadManager.resumeOutstanding()
        await refresh()
    }

    func tick() async {
        await tickDownloads()
        await refresh()
    }

    // MARK: - AppState-facing operations

    func downloadTracks(_ rows: [TrackRow]) async {
        let baseRevision = (try? await downloadStore.currentRevision()) ?? 0
        for row in rows {
            let id = PhoneWatchID.track(row.track)
            let root = PhoneWatchDownloadRoot(
                rootID: "track:\(id.rawValue)", kind: .track, sourceID: id.rawValue,
                title: row.track.title, desiredTrackIDs: [id.rawValue],
                phoneRevision: baseRevision)
            try? await downloadManager.addRoot(root)
        }
        await refresh()
    }

    func downloadPlaylist(id playlistID: Int64) async {
        guard let playlist = try? await store.playlist(id: playlistID) else { return }
        let rows = (try? await store.playlistTrackRows(playlistId: playlistID)) ?? []
        let trackIDs = rows.map { PhoneWatchID.track($0.row.track).rawValue }
        guard !trackIDs.isEmpty else { return }
        let root = PhoneWatchDownloadRoot(
            rootID: "playlist:\(PhoneWatchID.playlist(playlist))",
            kind: .playlist, sourceID: PhoneWatchID.playlist(playlist),
            title: playlist.title, desiredTrackIDs: trackIDs,
            phoneRevision: (try? await downloadStore.currentRevision()) ?? 0)
        try? await downloadManager.addRoot(root)
        await refresh()
    }

    func removeTracks(_ rows: [TrackRow]) async {
        let ids = rows.map { PhoneWatchID.track($0.track) }
        for id in ids {
            try? await downloadManager.removeRoot(rootID: "track:\(id.rawValue)")
        }
        _ = await coordinator.sendRemoveAssets(ids)
        await refresh()
    }

    func removeAll() async {
        let installed = installedTrackIDs.map(WatchTrackID.init)
        try? await downloadManager.setRoots([])
        if !installed.isEmpty { _ = await coordinator.sendRemoveAssets(installed) }
        await refresh()
    }

    func requestReconciliation() async {
        await coordinator.requestReconciliation()
    }

    // MARK: - Inbound (called back from PhoneWatchInbound)

    fileprivate func ingestManifest(_ payload: WatchManifestPayload) async {
        try? await downloadManager.ingestManifest(payload)
        await refresh()
    }

    fileprivate func tickDownloads() async {
        try? await downloadManager.tick()
        await refresh()
    }

    // MARK: - Internal

    private func refresh() async {
        let entries = (try? await downloadStore.manifestEntries()) ?? []
        let jobs = (try? await downloadStore.jobs()) ?? []
        installedTrackIDs = Set(entries.map(\.trackID))
        installedBytes = entries.reduce(0) { $0 + $1.bytes }
        activeJobCount = jobs.filter {
            $0.state == .queued || $0.state == .resolving || $0.state == .transferring
                || $0.state == .waitingForWiFi
        }.count
        failedJobCount = jobs.filter { $0.state == .failed }.count
        jobStateByTrackID = Dictionary(jobs.map { ($0.trackID, $0.state.rawValue) },
                                       uniquingKeysWith: { a, _ in a })
        let state = await coordinator.connectionState
        connected = Self.isConnected(state)
        onChange?()
    }

    private static func isConnected(_ state: WatchConnectionReducer.State) -> Bool {
        switch state {
        case .connected, .suspectedDisconnected: return true
        default: return false
        }
    }

    /// A stable per-install identity for this phone library. §5.4: it changes only on a library
    /// reset or reinstall, at which point the watch prompts before replacing unrelated downloads.
    private static func resolveLibraryID() -> WatchPairedLibraryID {
        let key = "watch.protocol.pairedLibraryID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return WatchPairedLibraryID(existing)
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return WatchPairedLibraryID(fresh)
    }
}

/// Bridges the `PhoneWatchDownloadStore` GRDB revision counter into the protocol coordinator's
/// `WatchPhoneRevisionStore` seam, so both halves of the phone stamp the same monotonic value.
private actor PhoneWatchDownloadRevisionAdapter: WatchPhoneRevisionStore {
    private let store: PhoneWatchDownloadStore
    init(store: PhoneWatchDownloadStore) { self.store = store }
    func currentRevision() async -> Int64 { (try? await store.currentRevision()) ?? 0 }
    func nextRevision() async -> Int64 { (try? await store.bumpRevision()) ?? 0 }
}

/// Late-bound trampoline for the request handler's manifest / reconciliation callbacks. The handler
/// needs them at construction — before `PhoneWatchRuntime` exists — so they land here and are
/// forwarded once `connect` supplies the runtime.
private actor PhoneWatchInbound {
    private weak var runtime: PhoneWatchRuntime?

    func connect(_ runtime: PhoneWatchRuntime) { self.runtime = runtime }

    func manifest(_ payload: WatchManifestPayload) async {
        await runtime?.ingestManifest(payload)
    }

    func reconciliation(_ request: WatchReconciliationRequest) async {
        await runtime?.tickDownloads()
    }
}
#endif
