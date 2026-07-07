import SwiftUI

@main
struct TonearmApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var player = AudioPlayer.shared

    init() {
        if ProcessInfo.processInfo.arguments.contains("UI_TESTING") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .task { await appState.bootstrap() }
        }
    }
}
