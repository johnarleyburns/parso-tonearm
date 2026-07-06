import SwiftUI

@main
struct TonearmApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var player = AudioPlayer.shared

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
