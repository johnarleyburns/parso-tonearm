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

    // MARK: - Connected content (W1 browse, W3 collection detail, play-on-iPhone)

    func browsePhonePlaylists() async -> [WatchResultRow] {
        guard let coordinator else { return [] }
        if case .results(let response) = await coordinator.browse(.playlists) { return response.rows }
        return []
    }

    func loadPhoneCollection(_ ref: WatchCollectionRef) async -> WatchCollectionResponse? {
        guard let coordinator, case .success(let response) = await coordinator.collection(ref) else {
            return nil
        }
        return response
    }

    @discardableResult
    func playOnPhone(_ command: WatchPlayCommand) async -> Bool {
        guard let coordinator else { return false }
        let accepted = await coordinator.send(command).accepted
        // A "play" that started something on the phone is the user choosing the iPhone target
        // (§7.1). A plain transport nudge (next/pause/…) leaves the current target alone.
        if accepted, command.action == .playCollection || command.action == .playTrack {
            WatchPlaybackCoordinator.shared.setTarget(.iPhone)
        }
        return accepted
    }

    /// §7.1: ask the phone for a fresh authoritative playback snapshot (drives the W7 correction
    /// poll). No-op when the link is unavailable.
    /// §7 polish — ask the phone to download (or drop) one track to this watch, from Now Playing.
    /// The phone stays the download authority; this only asks.
    func requestDownloadToThisWatch(_ trackID: WatchTrackID, wants: Bool = true) async {
        await coordinator?.requestDownload(trackID: trackID, wantsDownload: wants)
    }

    func refreshRemotePlayback() async {
        await coordinator?.refreshPlaybackSnapshot()
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
        WatchPlayer.shared.play(tracks: tracks, startAt: start)
        if let seekTo, seekTo > 0 { WatchPlayer.shared.seek(to: seekTo) }
    }

    private init() {
        let bootstrap = WatchStoreBootstrap.open()
        self.audioDirectory = bootstrap.audioDirectory
        self.launchState = bootstrap.state
        self.stateStore = WatchDefaultsSyncStateStore()
        let chrome = WatchConnectionChrome()
        self.chrome = chrome

        guard let container = bootstrap.container, let audio = bootstrap.audioDirectory else {
            self.repository = nil
            self.installer = nil
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

        let repo = WatchLibraryRepository(container: container, audioDirectory: audio)
        let staging = audio.deletingLastPathComponent().appendingPathComponent("Staging", isDirectory: true)
        let inst = WatchFileInstaller(repository: repo, audioDirectory: audio, stagingDirectory: staging)
        let mdl = WatchLibraryModel(repository: repo, recoveryNotice: bootstrap.recoveryNotice)
        let reach = WatchReachabilityObserver(model: mdl)
        let diag = diagnostics
        let sync = WatchSyncActor(repository: repo, installer: inst, diagnostics: diag,
                                  onLibraryChanged: { [weak mdl] in await mdl?.refresh() })
        let coord = WatchConnectivityCoordinator(
            transport: WatchProtocolSessionAdapter.transport,
            stateStore: stateStore,
            diagnostics: diag,
            observer: nil)

        let searchPresenter = WatchSearchPresenter(
            mode: .offline,
            connectedSearch: { [weak coord] query, _ in
                guard let coord else { return .failed(.init(code: .phoneUnavailable)) }
                switch await coord.search(query) {
                case .results(let response): return .results(response)
                case .superseded: return .superseded
                case .failed(let fault): return .failed(fault)
                }
            },
            offlineSearch: { [weak repo] query in
                let hits = (try? await repo?.search(query, readyOnly: true)) ?? []
                return hits.map {
                    WatchResultRow(kind: .track, id: $0.id, title: $0.title,
                                   subtitle: $0.artist.isEmpty ? nil : $0.artist,
                                   durationSeconds: $0.durationSeconds, isDownloadedOnWatch: true)
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
