import SwiftUI
import TonearmCore

@main
struct PlatterheadWatchApp: App {
    #if DEBUG
    @State private var didSeed = false
    #endif

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchRootView()
                    .navigationTitle("Platterhead")
            }
            #if DEBUG
            .task {
                guard !didSeed else { return }
                didSeed = true
                if ProcessInfo.processInfo.arguments.contains("SEED_WATCH_FIXTURES") {
                    WatchFixtureSeeder.seed()
                }
            }
            #endif
        }
    }
}
