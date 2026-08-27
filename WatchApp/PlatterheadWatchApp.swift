import SwiftUI
import TonearmWatchCore

@main
struct PlatterheadWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var didSeed = false
    #endif

    init() {
        WatchAppAssembly.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .task { await WatchPlayer.shared.restorePositionIfAvailable() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .inactive:
                        WatchPlayer.shared.persistNow()
                    case .background:
                        WatchPlayer.shared.handleAudioEvent(.appDidBackground)
                    case .active:
                        WatchPlayer.shared.handleAudioEvent(.appWillForeground)
                    @unknown default:
                        break
                    }
                }
            #if DEBUG
                .task {
                    guard !didSeed else { return }
                    didSeed = true
                    if ProcessInfo.processInfo.arguments.contains("SEED_WATCH_FIXTURES"),
                       let repository = WatchAppAssembly.shared.repository,
                       let audio = WatchAppAssembly.shared.audioDirectory {
                        await WatchFixtureSeeder.seed(repository: repository, audioDirectory: audio)
                        await WatchAppAssembly.shared.model.refresh()
                    }
                }
            #endif
        }
    }
}

/// Hosts navigation in a real `View` (not the `App`/`Scene`) so it observes `WatchPlayer` reliably.
/// Now Playing is presented as a boolean-bound sheet rather than a programmatic `NavigationPath`
/// push: external mutations to a `NavigationPath` binding do not reliably drive the stack on
/// watchOS, which is why tapping "Play All" previously navigated nowhere.
struct WatchContentView: View {
    @ObservedObject private var player = WatchPlayer.shared
    @ObservedObject private var chrome = WatchAppAssembly.shared.chrome

    var body: some View {
        NavigationStack(path: $player.navigationPath) {
            WatchRootView()
                .navigationTitle("Platterhead")
                .navigationDestination(for: WatchNav.self) { nav in
                    switch nav {
                    case .search: WatchSearchView()
                    case .downloads: WatchDownloadsView()
                    case .playlists: WatchPlaylistsView()
                    case .albums: WatchAlbumsView()
                    case .songs: WatchSongsView()
                    case .storage: WatchStorageView()
                    case .playlist(let id): WatchPlaylistDetailView(playlistID: id)
                    case .album(let id): WatchAlbumDetailView(albumID: id)
                    case .phonePlaylists: WatchPhonePlaylistsView()
                    case .phoneCollection(let ref): WatchPhoneCollectionView(ref: ref)
                    case .recovery: WatchRecoveryView()
                    }
                }
        }
        .sheet(isPresented: $player.isShowingNowPlaying) {
            NavigationStack {
                WatchNowPlayingView()
            }
        }
        .sheet(isPresented: needsRecoveryScreen) {
            NavigationStack { WatchRecoveryView() }
        }
        .alert("Different iPhone Library", isPresented: pendingReplacement) {
            Button("Replace Downloads", role: .destructive) {
                WatchAppAssembly.shared.confirmLibraryReplacement()
            }
            Button("Keep Current", role: .cancel) {
                WatchAppAssembly.shared.rejectLibraryReplacement()
            }
        } message: {
            Text("This iPhone has a different music library. Replacing keeps this watch in sync but removes downloads that are no longer in it.")
        }
    }

    private var needsRecoveryScreen: Binding<Bool> {
        .init(get: { WatchAppAssembly.shared.launchState == .degraded },
              set: { _ in })
    }

    private var pendingReplacement: Binding<Bool> {
        .init(get: { chrome.pendingLibraryReplacement != nil },
              set: { if !$0 { WatchAppAssembly.shared.rejectLibraryReplacement() } })
    }
}
