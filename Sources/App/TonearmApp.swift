import SwiftUI
import TonearmCore

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

        if isUITesting {
            UserDefaults.standard.set(true, forKey: "didOnboard")
        }
        if shouldSeedProForUITesting {
            ProEntitlement.persist(.verified(transactionID: 1, purchaseDate: Date(timeIntervalSince1970: 0)))
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
