import SwiftUI
import TonearmCore

@main
struct TonearmApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var player = AudioPlayer.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if ProcessInfo.processInfo.arguments.contains("UI_TESTING") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
        }
        ProStore.shared.start()
        AudioPlayer.shared.attachPlatformBridge(SystemPlaybackBridge())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .task { await appState.bootstrap() }
                .onOpenURL { url in
                    Task { await appState.handleIncomingURL(url) }
                }
                .task {
                    if #available(iOS 17.0, *) {
                        await CloudSyncEngine.shared.reconcile()
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    let added = await FolderWatchService.shared.rescanWatchedFolders(store: appState.store)
                    if added > 0 { await appState.reload() }
                }
                if #available(iOS 17.0, *) {
                    Task { await CloudSyncEngine.shared.reconcile() }
                }
            case .background, .inactive:
                AudioPlayer.shared.persistNow()
            default:
                break
            }
        }
    }
}
