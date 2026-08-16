import SwiftUI
import TonearmCore
import TonearmDJ

@main
struct TonearmApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var player = AudioPlayer.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var didCompleteBootstrap = false

    init() {
        let launchArguments = ProcessInfo.processInfo.arguments
        let isUITesting = launchArguments.contains("UI_TESTING")
        let shouldSeedProForUITesting = isUITesting && launchArguments.contains("UI_TESTING_ENABLE_PRO")

        if launchArguments.contains("-resetLibrary") {
            Self.resetLibraryForRegression()
        }
        if launchArguments.contains("-midiSeedProfile") {
            Self.seedMidiProfileForRegression()
        }
        if isUITesting {
            UserDefaults.standard.set(true, forKey: "didOnboard")
        }
        if shouldSeedProForUITesting {
            ProEntitlement.persist(.verified(transactionID: 1, purchaseDate: Date(timeIntervalSince1970: 0)))
            // The defaults flag above is the older entitlement record; every
            // Pro capability (App. T.3) gates on `EntitlementStore.isPro`,
            // which reads its own cache. Seed both, or the DJ surfaces stay
            // dimmed and inert for the whole run.
            EntitlementStore.shared.grantForUITesting()
        }
        if launchArguments.contains("UI_TESTING_RESET_PRO") {
            ProEntitlement.clear()
        }
        if !shouldSeedProForUITesting {
            ProStore.shared.start()
            EntitlementStore.shared.start()
        }
        AudioPlayer.shared.attachPlatformBridge(SystemPlaybackBridge())
        AudioPlayer.shared.persistor.cloudBackend = CloudPlaybackBackend()
    }

    /// The `-resetLibrary` harness hook (dj-regression-suite §8.1): wipe the
    /// app's library state so a regression run always starts from the same
    /// empty slate — the main store, the DJ database (tracks, crates, the
    /// mixes journal), recorded mixes, genre-crate downloads and the DJ caches.
    /// Runs before any store is opened, so it is safe to delete the DB files.
    private static func resetLibraryForRegression() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for suffix in ["", "-shm", "-wal"] {
            try? fm.removeItem(at: appSupport.appendingPathComponent("library\(suffix).sqlite"))
        }
        guard let djDatabase = try? DJDatabase.defaultDatabaseURL() else { return }
        for suffix in ["", "-shm", "-wal"] {
            try? fm.removeItem(at: URL(fileURLWithPath: djDatabase.path + suffix))
        }
        try? fm.removeItem(at: DJDatabase.mixesDirectory)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: documents.appendingPathComponent("GenreCrates", isDirectory: true))
        try? fm.removeItem(at: DJDatabase.cachesDirectory)
    }

    /// The AT-HW-06 harness hook (plan dj-midi-alpha M1): write an **active**
    /// profile binding CC 7 to the crossfader, so the workspace attaches MIDI
    /// when the decks open and the injection hook's CC has somewhere to land.
    /// Runs after `-resetLibrary`, so the wipe never clears it.
    private static func seedMidiProfileForRegression() {
        var profile = ControllerProfile(name: "Regression controller",
                                        endpointName: "Regression")
        // `.jump`: the lane injects one CC and expects the crossfader to move
        // immediately — pickup would correctly refuse until a "physical"
        // crossing, which an injected message can never produce.
        profile.learn(.crossfader,
                      at: MidiAddress(type: .cc, channel: 1, number: 7),
                      transform: .bipolar, takeover: .jump)
        try? ControllerProfileStore(pool: DJLibraryStore.shared.pool)
            .save(profile, syncID: "regression")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .task {
                    await appState.bootstrap()
                    didCompleteBootstrap = true
                }
                .onOpenURL { url in
                    Task { await appState.handleIncomingURL(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                guard didCompleteBootstrap else { return }
                Task {
                    let added = await FolderWatchService.shared.rescanWatchedFolders(store: appState.store)
                    if added > 0 { await appState.reload() }
                }
            case .background, .inactive:
                AudioPlayer.shared.persistNow()
            default:
                break
            }
        }
    }
}
