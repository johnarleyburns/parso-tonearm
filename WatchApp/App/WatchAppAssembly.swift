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

    // MARK: - Synced catalog compatibility

    func loadPhoneCollection(_ ref: WatchCollectionRef, pageToken: String? = nil) async -> WatchCollectionResponse? {
        nil
    }

    /// Watch redesign B1 — one page of the iPhone's playlists or albums; `nil` when the phone
    /// couldn't be reached (the screen says so and offers Try Again).
    func browsePhone(_ category: WatchBrowseCategory, pageToken: String? = nil) async -> WatchBrowseResponse? {
        return nil
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

    /// Watch redesign D1 — Pause / Resume / Stop / Retry from "On This Watch".
    func controlDownloads(_ action: WatchDownloadControlAction, rootID: String? = nil) async {
        await coordinator?.controlDownloads(WatchDownloadControl(action: action, rootID: rootID))
    }

    /// Watch redesign B3 — ask the phone to download one song from a long-press menu.
    func requestDownloads(_ trackIDs: [WatchTrackID]) async {
        for id in trackIDs { await coordinator?.requestDownload(trackID: id, wantsDownload: true) }
    }


    /// §7.1: ask the phone for a fresh authoritative playback snapshot (drives the W7 correction
    /// poll). No-op when the link is unavailable.
    /// §7 polish — ask the phone to download (or drop) one track to this watch, from Now Playing.
    /// The phone stays the download authority; this only asks.
    func requestDownloadToThisWatch(_ trackID: WatchTrackID, wants: Bool = true) async {
        await coordinator?.requestDownload(trackID: trackID, wantsDownload: wants)
    }

    func refreshRemotePlayback() async {
        // Deliberately empty. The phone is a sync/download authority only; playback snapshots
        // are not polled from the watch and no watch action can start iPhone playback.
    }

    // MARK: - Continue on Apple Watch (§7.5)

    /// Track IDs whose audio is actually present on this watch — the set the §7.5 plan is built
    /// against.
    func locallyAvailableTrackIDs() async -> Set<WatchTrackID> {
        guard let repository, let audioDirectory else { return [] }
        let rows = (try? await repository.tracks(readyOnly: true)) ?? []
        let fm = FileManager.default
        return Set(rows.compactMap { row -> WatchTrackID? in
            guard let name = row.localFilename,
                  fm.fileExists(atPath: audioDirectory.appendingPathComponent(name).path)
            else { return nil }
            return WatchTrackID(row.id)
        })
    }

    /// Resolve a §7.5 plan into local snapshots and hand it to the local player, resumed at the
    /// last authoritative anchor. Labelled, brief pause, begins locally — never gapless.
    func startContinueOnWatch(_ plan: WatchContinueOnWatchPlan) async {
        await playLocalTrackIDs(plan.trackIDs, startAt: plan.startIndex,
                                seekTo: plan.elapsedAnchor > 0 ? plan.elapsedAnchor : nil)
    }

    /// Resolve phone track IDs to the watch's own ready snapshots and play them locally, dropping
    /// any that aren't downloaded here. Used by the §7.1 cross-target "Play on Apple Watch" action
    /// and by Continue on Apple Watch.
    func playLocalTrackIDs(_ ids: [WatchTrackID], startAt: Int = 0, seekTo: Double? = nil) async {
        guard let repository else { return }
        let rows = (try? await repository.tracks(readyOnly: true)) ?? []
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let anchor = ids.indices.contains(startAt) ? ids[startAt] : ids.first
        let tracks = ids.compactMap { byID[$0.rawValue] }
        guard !tracks.isEmpty else { return }
        let start = anchor.flatMap { a in tracks.firstIndex { $0.id == a.rawValue } } ?? 0
        let selectedID = tracks[start].id
        WatchPlayer.shared.startLocalPlayback(tracks: tracks, selectedTrackID: selectedID,
                                               seekTo: seekTo)
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
        let staging = audio.deletingLastPathComponent().appendingPathComponent("Staging", isDirectory: true)
        let inst = WatchFileInstaller(repository: repo, audioDirectory: audio, stagingDirectory: staging)
        let artworkStaging = audio.deletingLastPathComponent().appendingPathComponent("StagingArtwork", isDirectory: true)
        let artworkInst = WatchArtworkInstaller(repository: repo, artworkDirectory: artwork,
                                                 stagingDirectory: artworkStaging)
        let mdl = WatchLibraryModel(repository: repo, recoveryNotice: bootstrap.recoveryNotice)
        let reach = WatchReachabilityObserver(model: mdl)
        let diag = diagnostics
        let sync = WatchSyncActor(repository: repo, installer: inst,
                                  artworkInstaller: artworkInst, diagnostics: diag,
                                  onLibraryChanged: { [weak mdl] in await mdl?.refresh() })
        let coord = WatchConnectivityCoordinator(
            transport: WatchProtocolSessionAdapter.transport,
            stateStore: stateStore,
            configuration: .init(capabilities: [.downloadRoots, .manifestAcknowledgement,
                                                .reconciliation, .watchInitiatedDownload,
                                                .artworkAssets, .watchLocalCatalog]),
            diagnostics: diag,
            observer: nil)

        let searchPresenter = WatchSearchPresenter(
            mode: .offline,
            connectedSearch: { _, _ in .failed(.init(code: .phoneUnavailable)) },
            offlineSearch: { [weak repo] query in
                let hits = (try? await repo?.search(query, readyOnly: false)) ?? []
                return hits.map {
                    WatchResultRow(kind: .track, id: $0.id, title: $0.title,
                                   subtitle: $0.artist.isEmpty ? nil : $0.artist,
                                   durationSeconds: $0.durationSeconds, isDownloadedOnWatch: $0.isReady)
                }
            })
        self.search = searchPresenter

        let chromeObs = WatchChromeObserver(chrome: chrome, model: mdl, search: searchPresenter)
        let remotePlayback = WatchRemotePlaybackObserver()
        let diagObs = WatchDiagnosticsObserver(diagnostics: diag)
        let downloadStatusObs = WatchDownloadStatusObserver(model: mdl)
        let fan = WatchFanoutObserver([sync, reach, chromeObs, remotePlayback, diagObs, downloadStatusObs])
        let adpt = WatchProtocolSessionAdapter(endpoint: coord)

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

        let fanForTask = fan
        Task {
            await sync.setCoordinator(coord)
            await coord.setObserver(fanForTask)
        }
    }

    /// Called once from the app's `init`. Activates the WCSession delegate and runs the one-time
    /// migration of audio left behind by the pre-cutover watch build.
    func start() {
        adapter?.activate()
        WatchWidgetPublisher.shared.start()
        let launch = launchState
        Task {
            await diagnostics.record(.activation, "started")
            await diagnostics.record(.storeRecovery, launch.rawValue)
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
