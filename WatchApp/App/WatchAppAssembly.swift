import Foundation
import TonearmWatchCore
import TonearmWatchProtocol

/// Builds and owns the watch's runtime graph: the SwiftData repository, the file installer, the
/// connectivity coordinator and its transport adapter, the sync actor that turns link events into
/// local truth, and the `@MainActor` model the views bind to.
///
/// Phase 6 cutover: `LibraryStore`/GRDB and `WatchSyncHandler` are gone. SwiftData is the only
/// persistence path; offline content is whatever `WatchLibraryRepository` says is ready.
@MainActor
final class WatchAppAssembly {
    let syncStatus: WatchSyncStatusState
    static let shared = WatchAppAssembly()

    let repository: WatchLibraryRepository?
    let audioDirectory: URL?
    let artworkDirectory: URL?
    let model: WatchLibraryModel
    let chrome: WatchConnectionChrome
    let search: WatchSearchPresenter
    /// The store's launch state — drives the W12 recovery screen.
    let launchState: WatchStoreLaunchState

    /// §12 — the privacy-safe diagnostics sink. Call sites record coarse state codes and numeric
    /// measurements; `WatchDiagnosticsView` renders the per-export-hashed JSON.
    let diagnostics = WatchDiagnosticsRecorder()

    private let coordinator: WatchConnectivityCoordinator?
    private let installer: WatchFileInstaller?
    private let artworkInstaller: WatchArtworkInstaller?
    private let syncActor: WatchSyncActor?
    private let fanout: WatchFanoutObserver?
    private let chromeObserver: WatchChromeObserver?
    private let reachability: WatchReachabilityObserver?
    private let adapter: WatchProtocolSessionAdapter?
    private let stateStore: WatchDefaultsSyncStateStore

    /// Ask the phone to replace the bound library after the user confirmed the A-08 prompt.
    func confirmLibraryReplacement() {
        chrome.resolveLibraryReplacement()
        guard let coordinator else { return }
        Task { await coordinator.confirmPairedLibraryReplacement() }
    }

    func rejectLibraryReplacement() {
        chrome.resolveLibraryReplacement()
        guard let coordinator else { return }
        Task { await coordinator.rejectPairedLibraryReplacement() }
    }

    @available(*, deprecated, message: "Watch playback is local-only; use WatchPlayer instead.")
    @discardableResult
    func playOnPhone(_ command: WatchPlayCommand, title: String? = nil) async -> Bool {
        // The phone is a sync/download authority only. Keeping this compatibility shim avoids a
        // source break for older views, but it can never send a play command over WCSession.
        return false
    }

    /// S4 "Play on Watch": the downloaded part of what the phone refused, in order.
    func localAlternative(for command: WatchPlayCommand) -> [WatchTrackSnapshot] {
        if let collection = command.collection, collection.kind == .playlist {
            let tracks = model.readyTracks(forPlaylist: collection.id)
            if !tracks.isEmpty { return tracks }
        }
        if let trackID = command.trackID, let track = model.track(id: trackID.rawValue) {
            return [track]
        }
        return []
    }

    func playLocalAlternative(for command: WatchPlayCommand) async {
        let tracks = localAlternative(for: command)
        guard !tracks.isEmpty else { return }
        WatchRemotePlayer.shared.setStartFailure(nil)
        let selected = command.trackID.flatMap { id in tracks.first { $0.id == id.rawValue } } ?? tracks[0]
        WatchPlayer.shared.startLocalPlayback(tracks: tracks, selectedTrackID: selected.id)
    }

    func refreshSyncReachability() async {
        await coordinator?.refreshReachability()
        await syncStatus.refreshInstallationDate()
    }

    func finishBackgroundDelivery() async {
        await adapter?.waitForBackgroundDelivery()
    }

    func requestSyncStatus() async {
        guard WatchProtocolSessionAdapter.isPhoneReachable else {
            syncStatus.setPhoneReachable(false)
            syncStatus.completedSync(.failed(.phoneUnavailable))
            return
        }
        guard !syncStatus.isSyncing else { return }
        let requestID = syncStatus.requestedSync()
        // UI deadline is independent of the coordinator's local database reads.
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard syncStatus.isSyncing else { return }
            syncStatus.completedSync(.failed(.requestTimedOut), requestID: requestID)
        }
        diagnostics.recordImmediately(.request, "metadataCheckRequested")
        let result = await coordinator?.synchronizeMetadata() ?? .failed(.installationFailed)
        if result != .sent { deadline.cancel() }
        diagnostics.recordImmediately(.request, "metadataCheckFinished")
        syncStatus.completedSync(result, requestID: requestID)
    }


    func refreshRemotePlayback() async {
        // Deliberately empty. The phone is a sync/download authority only; playback snapshots
        // are not polled from the watch and no watch action can start iPhone playback.
    }

    private init() {
        let bootstrap = WatchStoreBootstrap.open()
        self.audioDirectory = bootstrap.audioDirectory
        self.artworkDirectory = bootstrap.artworkDirectory
        self.launchState = bootstrap.state
        self.stateStore = WatchDefaultsSyncStateStore()
        let chrome = WatchConnectionChrome()
        self.chrome = chrome

        guard let container = bootstrap.container, let audio = bootstrap.audioDirectory else {
            self.syncStatus = WatchSyncStatusState()
            self.repository = nil
            self.installer = nil
            self.artworkInstaller = nil
            self.syncActor = nil
            self.coordinator = nil
            self.fanout = nil
            self.chromeObserver = nil
            self.reachability = nil
            self.adapter = nil
            self.model = WatchLibraryModel(repository: nil, recoveryNotice: bootstrap.recoveryNotice)
            self.search = WatchSearchPresenter(
                mode: .offline, connectedSearch: { _, _ in .failed(.init(code: .phoneUnavailable)) },
                offlineSearch: { _ in [] })
            return
        }

        let artwork = bootstrap.artworkDirectory ?? audio.deletingLastPathComponent().appendingPathComponent("WatchArtwork", isDirectory: true)
        let repo = WatchLibraryRepository(container: container, audioDirectory: audio, artworkDirectory: artwork)
        let syncStatus = WatchSyncStatusState(latestInstallation: { try? await repo.lastAudioInstallationDate() })
        self.syncStatus = syncStatus
        let staging = audio.deletingLastPathComponent().appendingPathComponent("Staging", isDirectory: true)
        let inst = WatchFileInstaller(repository: repo, audioDirectory: audio, stagingDirectory: staging)
        let artworkStaging = audio.deletingLastPathComponent().appendingPathComponent("StagingArtwork", isDirectory: true)
        let artworkInst = WatchArtworkInstaller(repository: repo, artworkDirectory: artwork,
                                                 stagingDirectory: artworkStaging)
        let mdl = WatchLibraryModel(repository: repo, recoveryNotice: bootstrap.recoveryNotice)
        let reach = WatchReachabilityObserver(model: mdl)
        let diag = diagnostics
        let sync = WatchSyncActor(repository: repo, installer: inst,
                                  requiresNormalizedAAC: true,
                                  localDownloadsOnly: true,
                                  artworkInstaller: artworkInst, diagnostics: diag,
                                  lastCatalogReceivedAt: syncStatus.lastCatalogSyncAt,
                                  onLibraryChanged: { [weak mdl] in await mdl?.refresh() })
        let searchPresenter = WatchSearchPresenter(
            mode: .offline,
            connectedSearch: { _, _ in .failed(.init(code: .phoneUnavailable)) },
            offlineSearch: { [weak repo] query in
                let hits = (try? await repo?.search(query, readyOnly: true)) ?? []
                return hits.map {
                    WatchResultRow(kind: .track, id: $0.id, title: $0.title,
                                   subtitle: $0.artist.isEmpty ? nil : $0.artist,
                                   durationSeconds: $0.durationSeconds, isDownloadedOnWatch: $0.isReady)
                }
            })
        self.search = searchPresenter

        let chromeObs = WatchChromeObserver(chrome: chrome, model: mdl, search: searchPresenter)
        let diagObs = WatchDiagnosticsObserver(diagnostics: diag)
        let downloadStatusObs = WatchDownloadStatusObserver(model: mdl)
        let fan = WatchFanoutObserver([sync, reach, chromeObs, diagObs, downloadStatusObs, syncStatus])
        // The observer is installed before native activation, not in a later Task.
        // A background file can arrive immediately when WCSession activates.
        let coord = WatchConnectivityCoordinator(
            transport: WatchProtocolSessionAdapter.transport,
            stateStore: stateStore,
            configuration: .init(capabilities: [.downloadRoots, .manifestAcknowledgement,
                                                .reconciliation, .artworkAssets], phonePushOnly: true),
            diagnostics: diag, observer: fan,
            manifestProvider: { await sync.metadataManifest() })
        let adpt = WatchProtocolSessionAdapter(endpoint: coord, diagnostics: diag)

        self.repository = repo
        self.installer = inst
        self.artworkInstaller = artworkInst
        self.model = mdl
        self.reachability = reach
        self.syncActor = sync
        self.chromeObserver = chromeObs
        self.fanout = fan
        self.coordinator = coord
        self.adapter = adpt

        Task {
            await sync.setCoordinator(coord)
        }
    }

    /// Called once from the app's `init`. Activates the WCSession delegate and runs the one-time
    /// migration of audio left behind by the pre-cutover watch build.
    func start() {
        Task {
            await syncActor?.removeLegacyCatalogMetadata()
            adapter?.activate()
        }
        WatchWidgetPublisher.shared.start()
        let launch = launchState
        Task {
            await diagnostics.record(.activation, "started")
            await diagnostics.record(.storeRecovery, launch.rawValue)
        }
        if launch.requiresPhoneResync {
            // The recovery notice promises a check against the iPhone; actually request it.
            Task { await requestSyncStatus() }
        }
        guard let repository, let audioDirectory else { return }
        Task {
            await Self.migrateLegacyAudioIfNeeded(into: audioDirectory, repository: repository)
            await model.refresh()
        }
    }

    /// The current diagnostics export, ready to render. A fresh salt is drawn on every call, so the
    /// hashed correlation ids are not linkable between two exports (§12).
    func diagnosticsExport() async -> WatchDiagnosticsExport {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return await diagnostics.export(appVersion: version)
    }

    /// The pre-cutover watch stored audio in `Application Support/WatchAudio`. Move any survivors
    /// into the new store's audio directory; `WatchSyncActor` adopts them by checksum on the next
    /// reconciliation once the phone has re-declared the tracks.
    private static func migrateLegacyAudioIfNeeded(into audioDirectory: URL,
                                                   repository: WatchLibraryRepository) async {
        let key = "legacyAudioMigration.v1"
        if let done = try? await repository.metadata(key), done == "done" { return }
        let fm = FileManager.default
        let legacyRoots = [
            fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("WatchAudio", isDirectory: true),
            fm.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("WatchAudio", isDirectory: true)
        ].compactMap { $0 }
        for root in legacyRoots {
            guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for file in files where !file.hasDirectoryPath {
                let destination = audioDirectory.appendingPathComponent(file.lastPathComponent)
                guard !fm.fileExists(atPath: destination.path) else { continue }
                try? fm.moveItem(at: file, to: destination)
            }
        }
        try? await repository.setMetadata(key, to: "done")
    }
}
