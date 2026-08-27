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
    func refreshRemotePlayback() async {
        await coordinator?.refreshPlaybackSnapshot()
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
        let sync = WatchSyncActor(repository: repo, installer: inst,
                                  onLibraryChanged: { [weak mdl] in await mdl?.refresh() })
        let coord = WatchConnectivityCoordinator(
            transport: WatchProtocolSessionAdapter.transport,
            stateStore: stateStore,
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
        let fan = WatchFanoutObserver([sync, reach, chromeObs, remotePlayback])
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
        guard let repository, let audioDirectory else { return }
        Task {
            await Self.migrateLegacyAudioIfNeeded(into: audioDirectory, repository: repository)
            await model.refresh()
        }
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
