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
    private let artworkBindings: PhoneWatchArtworkBindingRegistry

    /// The phone player and its snapshot builder, kept so autonomous now-playing changes (a track
    /// ending, someone pressing play on the phone) are pushed to the watch as an application
    /// context — not only answered when the watch asks. §7.1.
    private let player: AudioPlayer
    private let playbackAdapter: PhoneWatchPlaybackAdapter
    /// A cheap structural fingerprint of the last pushed snapshot; `currentTime` drift is left to
    /// the watch's `requestSnapshot` poll so this does not churn the WCSession context.
    private var lastPushedFingerprint: String?

    /// Fired on the main actor whenever watch-derived state changes, so `AppState` can republish.
    var onChange: (@MainActor @Sendable () -> Void)?

    private(set) var installedTrackIDs: Set<String> = []
    private(set) var installedBytes: Int64 = 0
    private(set) var activeJobCount = 0
    private(set) var failedJobCount = 0
    private(set) var jobStateByTrackID: [String: String] = [:]
    private(set) var connected = false

    /// Phase 8: the full Settings › Apple Watch projection (P1–P5).
    private(set) var management = PhoneWatchManagementPresenter.Snapshot.empty

    private var lastWatchManifest: WatchManifestPayload?
    private var connectedSince: Date?

    init(store: LibraryStore, player: AudioPlayer) {
        self.store = store
        self.libraryID = Self.resolveLibraryID()

        let downloadStore = PhoneWatchDownloadStore(library: store)
        self.downloadStore = downloadStore

        let revisionStore = PhoneWatchDownloadRevisionAdapter(store: downloadStore)
        let negotiatedCapabilities = PhoneWatchNegotiatedCapabilities()
        let inbound = PhoneWatchInbound(negotiatedCapabilities: negotiatedCapabilities)
        self.inbound = inbound
        let artworkBindings = PhoneWatchArtworkBindingRegistry()
        self.artworkBindings = artworkBindings

        let downloadedProvider: @Sendable () async -> Set<WatchTrackID> = { [weak downloadStore] in
            guard let downloadStore else { return [] }
            let ids = (try? await downloadStore.installedTrackIDs()) ?? []
            return Set(ids.map(WatchTrackID.init))
        }

        let playbackAdapter = PhoneWatchPlaybackAdapter(player: player,
                                                        downloadedProvider: downloadedProvider,
                                                        artworkBindingProvider: { [artworkBindings] trackID in
                                                            await artworkBindings.binding(for: trackID)
                                                        })
        self.player = player
        self.playbackAdapter = playbackAdapter

        let requestHandler = PhoneWatchRequestHandler(
            store: store,
            player: playbackAdapter,
            libraryID: libraryID,
            revisionStore: revisionStore,
            downloadedProvider: downloadedProvider,
            artworkBindingProvider: { [artworkBindings] trackID in
                await artworkBindings.binding(for: trackID)
            },
            onManifest: { [inbound] payload in await inbound.manifest(payload) },
            onReconciliation: { [inbound] request in await inbound.reconciliation(request) },
            onDownloadRequest: { [inbound] request in await inbound.downloadRequest(request) })

        let coordinator = PhoneWatchProtocolCoordinator(
            transport: PhoneWatchProtocolAdapter.transport,
            handler: requestHandler,
            libraryID: libraryID,
            revisionStore: revisionStore,
            observer: inbound)
        self.coordinator = coordinator
        self.protocolAdapter = PhoneWatchProtocolAdapter(endpoint: coordinator)

        let audioResolver = PhoneWatchLibraryAudioResolver(store: store)
        let artworkResolver = PhoneWatchLibraryArtworkResolver(store: store)
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
            rootExpander: rootExpander,
            artworkResolver: artworkResolver,
            artworkTransfer: fileTransfer,
            artworkCapability: { [negotiatedCapabilities] in
                let session = PhoneWatchProtocolAdapter.currentCapability()
                guard session.isSupported && session.isPaired && session.isWatchAppInstalled else { return false }
                return await negotiatedCapabilities.supports(.artworkAssets)
            },
            publishArtworkBindings: { [artworkBindings] trackID, cover, custom in
                await artworkBindings.set(trackID: trackID, coverArtworkID: cover, customArtworkID: custom)
            })

        Task { await inbound.connect(self) }
    }

    // MARK: - Lifecycle

    func activate() async {
        protocolAdapter.activate()
        try? await downloadManager.resumeOutstanding()
        await refresh()
        await publishPlaybackIfChanged()
    }

    func tick() async {
        await tickDownloads()
        await refresh()
        await publishPlaybackIfChanged()
        await publishDownloadStatusIfActive()
    }

    /// Push a download-status context (with per-track byte progress) while a transfer is in flight,
    /// so the watch's Now Playing download ring can close. Silent when idle — I-10 forbids churn.
    private func publishDownloadStatusIfActive() async {
        guard var snapshot = try? await downloadManager.statusSnapshot() else { return }
        let fractions = PhoneWatchProtocolAdapter.activeAudioTransferFractions()
        snapshot.activeTransfers = fractions.map {
            WatchTransferProgress(trackID: WatchTrackID($0.key), fractionComplete: $0.value)
        }
        guard !snapshot.isIdle || !snapshot.activeTransfers.isEmpty else { return }
        await coordinator.publishContext(downloads: snapshot)
    }

    // MARK: - Autonomous now-playing push (§7.1)

    /// Push a fresh playback snapshot to the watch as an application context when the phone player's
    /// *structure* changed since the last push — a new track, play/pause, shuffle/repeat, a queue
    /// swap. Elapsed drift is deliberately not a trigger: the watch predicts it from the anchor and
    /// polls `requestSnapshot` while Now Playing is on screen, so pushing on every `currentTime`
    /// change would churn the WCSession context for nothing (I-10).
    private func publishPlaybackIfChanged() async {
        let fingerprint = [
            player.isPlaying ? "1" : "0",
            String(player.index),
            String(player.queue.count),
            player.queue.indices.contains(player.index)
                ? PhoneWatchID.track(player.queue[player.index].track).rawValue : "-",
            player.shuffle ? "s" : "-",
            String(describing: player.repeatMode)
        ].joined(separator: "|")

        guard fingerprint != lastPushedFingerprint else { return }
        let revision = (try? await downloadStore.currentRevision()) ?? 0
        let snapshot = await playbackAdapter.snapshot(revision: revision)
        if await coordinator.publishContext(playback: snapshot) {
            lastPushedFingerprint = fingerprint
        }
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
        await tickDownloads()
    }

    func artworkDidChange() async {
        try? await downloadManager.artworkDidChange()
        await refresh()
    }

    // MARK: - Phase 8 management actions

    func pauseRoot(_ rootID: String) async {
        try? await downloadManager.pauseRoot(rootID: rootID)
        await refresh()
    }

    func resumeRoot(_ rootID: String) async {
        try? await downloadManager.resumeRoot(rootID: rootID)
        await refresh()
    }

    func removeRoot(_ rootID: String) async {
        let released = PhoneWatchManagementPresenter.tracksReleasedByRemoving(
            rootID: rootID,
            roots: (try? await downloadStore.roots()) ?? [],
            installed: (try? await downloadStore.installedTrackIDs()) ?? [])
        try? await downloadManager.removeRoot(rootID: rootID)
        let toRemove = released.released.map(WatchTrackID.init)
        if !toRemove.isEmpty { _ = await coordinator.sendRemoveAssets(toRemove) }
        await refresh()
    }

    func cancelJob(_ requestID: String) async {
        try? await downloadManager.cancelJob(requestID: requestID)
        await refresh()
    }

    func retryJob(_ requestID: String) async {
        try? await downloadManager.requestRetry(requestID: requestID)
        await refresh()
    }

    func collectionDetail(_ rootID: String) async -> PhoneWatchManagementPresenter.CollectionDetail? {
        let roots = (try? await downloadStore.roots()) ?? []
        let jobs = (try? await downloadStore.jobs()) ?? []
        let entries = (try? await downloadStore.manifestEntries()) ?? []
        return PhoneWatchManagementPresenter.collectionDetail(
            rootID: rootID, roots: roots, jobs: jobs, manifestEntries: entries)
    }

    // MARK: - Inbound (called back from PhoneWatchInbound)

    fileprivate func ingestManifest(_ payload: WatchManifestPayload) async {
        lastWatchManifest = payload
        try? await downloadManager.ingestManifest(payload)
        await refresh()
    }

    fileprivate func tickDownloads() async {
        try? await downloadManager.tick()
        await refresh()
    }

    /// §7 polish — the watch asked (from its Now Playing screen) to download or drop one track.
    /// The phone is still the authority: it resolves the id against the real library and turns the
    /// ask into a normal single-track download root (or removes that root).
    fileprivate func applyWatchDownloadRequest(_ request: WatchDownloadRequest) async {
        let id = request.trackID
        let rootID = "track:\(id.rawValue)"
        if request.wantsDownload {
            let row: TrackRow?
            if let localID = PhoneWatchID.trackRowID(id) {
                row = try? await store.trackRow(id: localID)
            } else {
                row = try? await store.trackRow(syncID: id.rawValue)
            }
            guard let row else { return }
            let root = PhoneWatchDownloadRoot(
                rootID: rootID, kind: .track, sourceID: id.rawValue,
                title: row.track.title, desiredTrackIDs: [id.rawValue],
                phoneRevision: (try? await downloadStore.currentRevision()) ?? 0)
            try? await downloadManager.addRoot(root)
        } else {
            try? await downloadManager.removeRoot(rootID: rootID)
            _ = await coordinator.sendRemoveAssets([id])
        }
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
        let wasConnected = connected
        connected = Self.isConnected(state)
        if connected && !wasConnected { connectedSince = Date() }
        if !connected { connectedSince = nil }

        let roots = (try? await downloadStore.roots()) ?? []
        management = PhoneWatchManagementPresenter.snapshot(
            pairing: currentPairing(),
            roots: roots, jobs: jobs, manifestEntries: entries,
            watchManifest: lastWatchManifest, now: Date())

        onChange?()
    }

    /// Maps the WCSession capability + protocol connection state onto the presenter's `Pairing`.
    private func currentPairing() -> PhoneWatchManagementPresenter.Pairing {
        let cap = PhoneWatchProtocolAdapter.currentCapability()
        guard cap.isSupported else { return .unsupported }
        guard cap.isPaired, cap.isWatchAppInstalled else { return .notPaired }
        return connected ? .connected(since: connectedSince) : .pairedNotReachable
    }

    /// The legacy display enum `WatchSettingsView` still reads, now derived from real capability.
    var sessionDisplayState: WatchSessionDisplayState {
        switch currentPairing() {
        case .unsupported: return .unsupported
        case .notPaired: return .notInstalled
        case .pairedNotReachable: return .installedNotReachable
        case .connected: return .reachable
        }
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
private actor PhoneWatchInbound: PhoneWatchProtocolObserver {
    private let negotiatedCapabilities: PhoneWatchNegotiatedCapabilities
    private weak var runtime: PhoneWatchRuntime?

    init(negotiatedCapabilities: PhoneWatchNegotiatedCapabilities) {
        self.negotiatedCapabilities = negotiatedCapabilities
    }

    func connect(_ runtime: PhoneWatchRuntime) { self.runtime = runtime }

    func watchDidNegotiate(_ hello: WatchHello) async {
        await negotiatedCapabilities.set(hello.capabilities)
    }

    func manifest(_ payload: WatchManifestPayload) async {
        await runtime?.ingestManifest(payload)
    }

    func reconciliation(_ request: WatchReconciliationRequest) async {
        await runtime?.tickDownloads()
    }

    func downloadRequest(_ request: WatchDownloadRequest) async {
        await runtime?.applyWatchDownloadRequest(request)
    }
}

private actor PhoneWatchNegotiatedCapabilities {
    private var capabilities: Set<WatchCapability> = []

    func set(_ capabilities: [WatchCapability]) { self.capabilities = Set(capabilities) }
    func supports(_ capability: WatchCapability) -> Bool { capabilities.contains(capability) }
}
#endif
