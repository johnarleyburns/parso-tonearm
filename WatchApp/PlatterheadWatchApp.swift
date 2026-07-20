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
            NavigationStack {
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
                        case .nowPlaying: WatchNowPlayingView()
                        }
                    }
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
