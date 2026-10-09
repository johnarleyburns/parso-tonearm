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
    private let requestHandler: PhoneWatchRequestHandler
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
    private var catalogTrackCount = 0
    private var audioAttempts: [String: String] = (UserDefaults.standard.dictionary(forKey: "watch.wholeAAC.attempts") as? [String: String]) ?? [:]
    private var syncHistory = PhoneWatchManagementPresenter.SyncHistory()
    private var connectedSince: Date?
    /// Watch redesign D1: download-status publishing state (see `publishDownloadStatusIfActive`).
    private var lastPublishedStatusContent: WatchDownloadStatusSnapshot?

    init(store: LibraryStore, player: AudioPlayer) {
        if let data = UserDefaults.standard.data(forKey: "watch.phone.manifest") {
            lastWatchManifest = try? JSONDecoder().decode(WatchManifestPayload.self, from: data)
        }
        if let data = UserDefaults.standard.data(forKey: "watch.phone.syncHistory"),
           let saved = try? JSONDecoder().decode(PhoneWatchManagementPresenter.SyncHistory.self, from: data) {
            self.syncHistory = saved
        }
        self.store = store
        self.libraryID = Self.resolveLibraryID()

        let downloadStore = PhoneWatchDownloadStore(library: store)
        self.downloadStore = downloadStore

        let revisionStore = PhoneWatchDownloadRevisionAdapter(store: downloadStore)
        let negotiatedCapabilities = PhoneWatchNegotiatedCapabilities(watchIdentifier: {
            PhoneWatchProtocolAdapter.currentWatchIdentifier()
        })
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
                                                        },
                                                        playlistResolver: { [weak store] rawID in
                                                            guard let store else { return nil }
                                                            let id: Int64?
                                                            if let rowID = PhoneWatchID.playlistRowID(rawID) {
                                                                id = rowID
                                                            } else {
                                                                id = try? await store.localID(table: "playlist", syncID: rawID)
                                                            }
                                                            guard let id else { return nil }
                                                            return try? await store.playlist(id: id)
                                                        })
        self.player = player
        self.playbackAdapter = playbackAdapter

        let requestHandler = PhoneWatchRequestHandler(
            store: store,
            player: playbackAdapter,
            libraryID: libraryID,
            revisionStore: revisionStore,
            capabilities: [.downloadRoots, .manifestAcknowledgement, .reconciliation, .artworkAssets],
            downloadedProvider: downloadedProvider,
            artworkBindingProvider: { [artworkBindings] trackID in
                await artworkBindings.binding(for: trackID)
            },
            onManifest: { [inbound] payload in await inbound.manifest(payload) },
            onReconciliation: { [inbound] request in await inbound.reconciliation(request) })
        self.requestHandler = requestHandler

        let coordinator = PhoneWatchProtocolCoordinator(
            transport: PhoneWatchProtocolAdapter.transport,
            handler: requestHandler,
            libraryID: libraryID,
            revisionStore: revisionStore,
            observer: inbound,
            allowsWatchDownloadCommands: false,
            downloadStatusProvider: { [inbound] in await inbound.metadataStatus() },
            metadataManifestHandler: { [inbound] in await inbound.metadataManifest($0) })
        self.coordinator = coordinator
        self.protocolAdapter = PhoneWatchProtocolAdapter(endpoint: coordinator,
            onAudioCompletion: { [inbound] metadata, code in
                await inbound.audioFinished(metadata, code: code)
            })

        let audioResolver = PhoneWatchLibraryAudioResolver(store: store)
        let artworkResolver = PhoneWatchLibraryArtworkResolver(store: store)
        let fileTransfer = PhoneWatchSessionFileTransfer(
            transport: PhoneWatchProtocolAdapter.transport,
            phoneRevision: { [weak downloadStore] in (try? await downloadStore?.currentRevision()) ?? 0 },
            onEnqueue: { [inbound] metadata in await inbound.audioEnqueued(metadata) })

        self.downloadManager = PhoneWatchDownloadManager(
            store: downloadStore,
            resolver: audioResolver,
            transfer: fileTransfer,
            emitRoots: { [weak coordinator, inbound] descriptors, _ in
                _ = await coordinator?.sendDownloadRoots(descriptors)
                await inbound.publishSelectedMetadata()
            },
            keepsPlaylistsLive: false,
            artworkResolver: artworkResolver,
            artworkTransfer: fileTransfer,
            artworkCapability: {
                let session = PhoneWatchProtocolAdapter.currentCapability()
                // Artwork is mandatory in our phone-push protocol. Production watches no longer
                // send a hello, so waiting for negotiated capabilities disables artwork forever.
                return session.isSupported && session.isPaired && session.isWatchAppInstalled
            },
            publishArtworkBindings: { [artworkBindings] trackID, cover, custom in
                await artworkBindings.set(trackID: trackID, coverArtworkID: cover, customArtworkID: custom)
            })

    }

    // MARK: - Lifecycle

    func activate() async {
        await inbound.connect(self)
        protocolAdapter.activate()
        await migrateLegacyTransfers()
        try? await downloadManager.resumeOutstanding()
        await publishCatalog()
        await refresh()
    }

    func tick() async {
        await tickDownloads(forceStatus: false)
        await refresh()
        await publishDownloadStatusIfActive()
    }

    /// Push a download-status context (with per-track byte progress) while a transfer is in flight,
    /// so the watch's Now Playing download ring can close. Silent when idle — I-10 forbids churn.
    ///
    /// Watch redesign D1: one more push when work *becomes* idle (finished, paused or stopped), so
    /// "On This Watch" never shows a stale "Downloading" — then silence again.
    fileprivate func metadataStatus() async -> WatchDownloadStatusSnapshot? {
        let fractions = PhoneWatchProtocolAdapter.activeAudioTransferFractions()
        guard var snapshot = try? await downloadManager.statusSnapshot(transferFractions: fractions) else { return nil }
        snapshot.lastWatchReportAt = lastWatchManifest?.generatedAt
        snapshot.catalogTrackCount = catalogTrackCount
        snapshot.readyTrackIDs = installedTrackIDs.sorted().map(WatchTrackID.init)
        for index in snapshot.activities.indices {
            let id = snapshot.activities[index].trackID
            let row: TrackRow?
            if let localID = PhoneWatchID.trackRowID(id) { row = try? await store.trackRow(id: localID) }
            else { row = try? await store.trackRow(syncID: id.rawValue) }
            if let row { snapshot.activities[index].title = row.track.title }
        }
        let progressByTrack = fractions
        snapshot.activeTransfers = progressByTrack.map {
            WatchTransferProgress(trackID: WatchTrackID($0.key), fractionComplete: $0.value)
        }
        snapshot.activeCount = snapshot.activities.filter { $0.stage == .transferring }.count
        snapshot.queuedCount = snapshot.activities.filter { [.queued, .preparing, .waitingForDelivery].contains($0.stage) }.count
        return snapshot
    }

    private func publishDownloadStatusIfActive(force: Bool = false, mirrorLive: Bool = false) async {
        guard let snapshot = await metadataStatus() else { return }
        let content = snapshot.coalescingContent
        guard force || content != lastPublishedStatusContent else { return }
        if await coordinator.publishContext(downloads: snapshot, mirrorLive: mirrorLive) {
            syncHistory.lastStatusSentAt = snapshot.generatedAt
            persistSyncHistory()
            lastPublishedStatusContent = content
            await refresh()
        }
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

    func downloadTracks(_ rows: [TrackRow]) async throws {
        let baseRevision = (try? await downloadStore.currentRevision()) ?? 0
        for row in rows {
            let id = PhoneWatchID.track(row.track)
            let root = PhoneWatchDownloadRoot(
                rootID: "track:\(id.rawValue)", kind: .track, sourceID: id.rawValue,
                title: row.track.title, desiredTrackIDs: [id.rawValue],
                phoneRevision: baseRevision)
            try await downloadManager.addRoot(root)
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
        try? await downloadManager.removeTracks(Set(ids.map(\.rawValue)))
        _ = await coordinator.sendRemoveAssets(ids)
        await refresh()
    }

    func removeTrackFromWatch(_ id: String) async {
        try? await downloadManager.removeTracks([id])
        _ = await coordinator.sendRemoveAssets([WatchTrackID(id)])
        await publishCatalog()
        await refresh()
    }

    func removeAll() async {
        let installed = installedTrackIDs.union(((try? await downloadStore.jobs()) ?? []).map(\.trackID)).map(WatchTrackID.init)
        try? await downloadManager.setRoots([])
        if !installed.isEmpty { _ = await coordinator.sendRemoveAssets(installed) }
        await refresh()
    }

    func requestReconciliation() async {
        await publishCatalog()
        await coordinator.requestReconciliation()
        await tickDownloads()
    }

    func synchronizeMetadata() async -> WatchMetadataSyncResult {
        await publishDownloadStatusIfActive(force: true, mirrorLive: false)
        return await coordinator.synchronizeMetadata()
    }

    fileprivate func publishMetadataStatus() async {
        await publishDownloadStatusIfActive(force: true)
    }

    /// Sends the complete catalog after every negotiation or an explicit Settings refresh. Search
    /// on the watch never uses the request handler; this is the sole metadata path.
    func publishCatalog() async {
        // A catalog snapshot gets its own monotonic revision. This prevents a late page from an
        // earlier reconnect (with a different catalog UUID) from replacing a newer snapshot.
        let revision = (try? await downloadStore.bumpRevision()) ?? 0
        let roots = (try? await downloadStore.roots()) ?? []
        let ids = installedTrackIDs.union(roots.flatMap(\.desiredTrackIDs))
        let playlists = Set(roots.filter { $0.kind == .playlist }.map(\.sourceID))
        let selectedPlaylists = roots.filter { $0.kind == .playlist }.map {
            WatchLibraryPlaylist(playlistID: $0.sourceID, title: $0.title,
                                 trackIDs: $0.desiredTrackIDs.map(WatchTrackID.init))
        }
        guard let pages = try? await requestHandler.catalogPages(revision: revision,
            trackIDs: ids, playlistIDs: playlists, selectedPlaylists: selectedPlaylists) else { return }
        catalogTrackCount = pages.reduce(0) { $0 + $1.tracks.count }
        for page in pages { await coordinator.sendCatalogPage(page) }
        syncHistory.lastCatalogSentAt = Date()
        persistSyncHistory()
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
        let partials = Set(((try? await downloadStore.jobs()) ?? []).map(\.trackID))
        let released = PhoneWatchManagementPresenter.tracksReleasedByRemoving(
            rootID: rootID,
            roots: (try? await downloadStore.roots()) ?? [],
            installed: ((try? await downloadStore.installedTrackIDs()) ?? []).union(partials))
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
            rootID: rootID, roots: roots, jobs: jobs, manifestEntries: entries, keepsPlaylistsLive: false)
    }

    // MARK: - Inbound (called back from PhoneWatchInbound)

    fileprivate func ingestManifest(_ payload: WatchManifestPayload, reconcileDownloads: Bool = true) async {
        guard lastWatchManifest.map({ payload.generatedAt > $0.generatedAt }) ?? true else { return }
        lastWatchManifest = payload
        if let data = try? JSONEncoder().encode(payload) { UserDefaults.standard.set(data, forKey: "watch.phone.manifest") }
        syncHistory.lastWatchReportAt = Date()
        syncHistory.lastCatalogReceivedAt = payload.lastCatalogReceivedAt
        syncHistory.lastAudioInstalledAt = payload.lastAudioInstalledAt
        persistSyncHistory()
        try? await downloadManager.ingestManifest(payload, reconcileDownloads: reconcileDownloads)
        for (id, code) in payload.audioDownloadFailures where payload.audioFailureTransferIDs[id] == audioAttempts[id]
            && audioAttempts[id] != nil {
            try? await downloadManager.transferFailed(trackID: WatchTrackID(id), code: code)
        }
        await refresh()
    }

    fileprivate func tickDownloads(forceStatus: Bool = true) async {
        try? await downloadManager.tick()
        await refresh()
        if forceStatus { await publishDownloadStatusIfActive(force: true) }
    }

    fileprivate func migrateLegacyTransfers() async {
        let key = "watch.wholeAAC128.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for job in (try? await downloadStore.jobs()) ?? [] where job.state == .sent && !installedTrackIDs.contains(job.trackID) {
            PhoneWatchProtocolAdapter.cancelAudioTransfer(trackID: WatchTrackID(job.trackID))
            try? await downloadManager.transferFailed(trackID: WatchTrackID(job.trackID), code: .transferFailed)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// §7 polish — the watch asked (from its Now Playing screen) to download or drop one track.
    /// The phone is still the authority: it resolves the id against the real library and turns the
    /// ask into a normal single-track download root (or removes that root).
    /// Watch redesign D1 — Pause / Resume / Stop / Retry from the watch's "On This Watch" screen.
    fileprivate func applyWatchDownloadControl(_ control: WatchDownloadControl) async {
        try? await downloadManager.applyControl(control)
        if control.action == .stop {
            // Stopping a root removes it; tell the watch which tracks no root wants any more.
            let installed = (try? await downloadStore.manifestEntries())?.map(\.trackID) ?? []
            let desired = Set(((try? await downloadStore.roots()) ?? []).flatMap(\.desiredTrackIDs))
            let partials = Set(((try? await downloadStore.jobs()) ?? []).map(\.trackID))
            let orphaned = Set(installed).union(partials).filter { !desired.contains($0) }.map(WatchTrackID.init)
            if !orphaned.isEmpty { _ = await coordinator.sendRemoveAssets(orphaned) }
        }
        await refresh()
        await publishDownloadStatusIfActive(force: true)
    }

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
            try? await downloadManager.requestRetry(trackID: id.rawValue)
            try? await downloadManager.addRoot(root)
        } else {
            try? await downloadManager.removeRoot(rootID: rootID)
            _ = await coordinator.sendRemoveAssets([id])
        }
        await refresh()
    }

    fileprivate func fileTransferFailed(_ trackID: WatchTrackID, code: WatchProtocolErrorCode) async {
        try? await downloadManager.transferFailed(trackID: trackID, code: code)
        await refresh()
        await publishDownloadStatusIfActive(force: true)
    }

    fileprivate func fileTransferCompleted(_ trackID: WatchTrackID) async {
        try? await downloadManager.transferDelivered(trackID: trackID)
        await tickDownloads()
    }

    fileprivate func audioEnqueued(_ metadata: WatchAudioFileMetadata) {
        audioAttempts[metadata.trackID.rawValue] = metadata.transferID
        UserDefaults.standard.set(audioAttempts, forKey: "watch.wholeAAC.attempts")
    }

    fileprivate func audioFinished(_ metadata: WatchAudioFileMetadata, code: WatchProtocolErrorCode?) async {
        guard let attempt = metadata.transferID, audioAttempts[metadata.trackID.rawValue] == attempt else { return }
        if let code { await fileTransferFailed(metadata.trackID, code: code) }
        else { await fileTransferCompleted(metadata.trackID) }
    }

    // MARK: - Internal

    private func persistSyncHistory() {
        if let data = try? JSONEncoder().encode(syncHistory) {
            UserDefaults.standard.set(data, forKey: "watch.phone.syncHistory")
        }
    }

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
        var trackTitles: [String: String] = [:]
        for rawID in installedTrackIDs.union(roots.flatMap(\.desiredTrackIDs)).union(jobs.map(\.trackID)) {
            let id = WatchTrackID(rawID)
            let row: TrackRow?
            if let localID = PhoneWatchID.trackRowID(id) { row = try? await store.trackRow(id: localID) }
            else { row = try? await store.trackRow(syncID: id.rawValue) }
            if let row { trackTitles[rawID] = row.track.title }
        }
        management = PhoneWatchManagementPresenter.snapshot(
            pairing: currentPairing(),
            roots: roots, jobs: jobs, manifestEntries: entries,
            watchManifest: lastWatchManifest, now: Date(),
            transferFractions: PhoneWatchProtocolAdapter.activeAudioTransferFractions(),
            syncHistory: syncHistory, trackTitles: trackTitles)

        onChange?()
    }

    /// Maps the WCSession capability + protocol connection state onto the presenter's `Pairing`.
    private func currentPairing() -> PhoneWatchManagementPresenter.Pairing {
        let cap = PhoneWatchProtocolAdapter.currentCapability()
        guard cap.isSupported else { return .unsupported }
        guard cap.isPaired, cap.isWatchAppInstalled else { return .notPaired }
        return cap.isReachable ? .connected(since: connectedSince) : .pairedNotReachable
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
    func publishSelectedMetadata() async { await runtime?.publishCatalog() }
    private let negotiatedCapabilities: PhoneWatchNegotiatedCapabilities
    private weak var runtime: PhoneWatchRuntime?

    init(negotiatedCapabilities: PhoneWatchNegotiatedCapabilities) {
        self.negotiatedCapabilities = negotiatedCapabilities
    }

    func connect(_ runtime: PhoneWatchRuntime) { self.runtime = runtime }

    func watchDidNegotiate(_ hello: WatchHello) async {
        await negotiatedCapabilities.set(hello.capabilities)
        await runtime?.publishCatalog()
    }

    func manifest(_ payload: WatchManifestPayload) async {
        await runtime?.ingestManifest(payload)
    }

    func metadataStatus() async -> WatchDownloadStatusSnapshot? { await runtime?.metadataStatus() }

    func metadataManifest(_ payload: WatchManifestPayload) async {
        await runtime?.ingestManifest(payload, reconcileDownloads: false)
    }

    func reconciliation(_ request: WatchReconciliationRequest) async {
        if request.scope == .status {
            await runtime?.publishMetadataStatus()
            await runtime?.publishCatalog()
            return
        }
        await runtime?.tickDownloads()
    }

    func downloadRequest(_ request: WatchDownloadRequest) async {
        await runtime?.applyWatchDownloadRequest(request)
    }

    func fileTransferFailed(_ trackID: WatchTrackID, code: WatchProtocolErrorCode) async {
        await runtime?.fileTransferFailed(trackID, code: code)
    }

    func fileTransferCompleted(_ trackID: WatchTrackID) async {
        await runtime?.fileTransferCompleted(trackID)
    }

    func audioEnqueued(_ metadata: WatchAudioFileMetadata) async { await runtime?.audioEnqueued(metadata) }
    func audioFinished(_ metadata: WatchAudioFileMetadata, code: WatchProtocolErrorCode?) async {
        await runtime?.audioFinished(metadata, code: code)
    }

    func downloadControl(_ control: WatchDownloadControl) async {
        await runtime?.applyWatchDownloadControl(control)
    }
}

#endif
