import SwiftUI
import TonearmCore

@main
struct PlatterheadWatchApp: App {
    #if DEBUG
    @State private var didSeed = false
    #endif

    init() {
        WatchSyncHandler.shared.setup()
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
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

/// Hosts navigation in a real `View` (not the `App`/`Scene`) so it observes
/// `WatchPlayer` reliably. Now Playing is presented as a boolean-bound sheet
/// rather than a programmatic `NavigationPath` push: external mutations to a
/// `NavigationPath` binding do not reliably drive the stack on watchOS, which
/// is why tapping "Play All" previously navigated nowhere.
struct WatchContentView: View {
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        NavigationStack(path: $player.navigationPath) {
            WatchRootView()
                .navigationTitle("Platterhead")
                .navigationDestination(for: WatchNav.self) { nav in
                    switch nav {
                    case .playlists: WatchPlaylistsView()
                    case .albums: WatchAlbumsView()
                    case .songs: WatchSongsView()
                    case .storage: WatchStorageView()
                    case .playlist(let p): WatchPlaylistDetailView(playlist: p)
                    case .album(let a): WatchAlbumDetailView(album: a)
                    }
                }
        }
        .sheet(isPresented: $player.isShowingNowPlaying) {
            NavigationStack {
                WatchNowPlayingView()
            }
        }
    }
}
