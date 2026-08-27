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

    private let installer: WatchFileInstaller?
    private let syncActor: WatchSyncActor?
    private let coordinator: WatchConnectivityCoordinator?
    private let fanout: WatchFanoutObserver?
    private let reachability: WatchReachabilityObserver?
    private let adapter: WatchProtocolSessionAdapter?
    private let stateStore: WatchDefaultsSyncStateStore

    private init() {
        let bootstrap = WatchStoreBootstrap.open()
        self.audioDirectory = bootstrap.audioDirectory
        self.stateStore = WatchDefaultsSyncStateStore()

        guard let container = bootstrap.container, let audio = bootstrap.audioDirectory else {
            self.repository = nil
            self.installer = nil
            self.syncActor = nil
            self.coordinator = nil
            self.fanout = nil
            self.reachability = nil
            self.adapter = nil
            self.model = WatchLibraryModel(repository: nil, recoveryNotice: bootstrap.recoveryNotice)
            return
        }

        let repo = WatchLibraryRepository(container: container, audioDirectory: audio)
        let staging = audio.deletingLastPathComponent().appendingPathComponent("Staging", isDirectory: true)
        let inst = WatchFileInstaller(repository: repo, audioDirectory: audio, stagingDirectory: staging)
        let mdl = WatchLibraryModel(repository: repo, recoveryNotice: bootstrap.recoveryNotice)
        let reach = WatchReachabilityObserver(model: mdl)
        let sync = WatchSyncActor(repository: repo, installer: inst,
                                  onLibraryChanged: { [weak mdl] in await mdl?.refresh() })
        let fan = WatchFanoutObserver([sync, reach])
        let coord = WatchConnectivityCoordinator(
            transport: WatchProtocolSessionAdapter.transport,
            stateStore: stateStore,
            observer: fan)
        let adpt = WatchProtocolSessionAdapter(endpoint: coord)

        self.repository = repo
        self.installer = inst
        self.model = mdl
        self.reachability = reach
        self.syncActor = sync
        self.fanout = fan
        self.coordinator = coord
        self.adapter = adpt

        Task { await sync.setCoordinator(coord) }
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
