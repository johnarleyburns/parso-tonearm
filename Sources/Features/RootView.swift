import SwiftUI
import TonearmCore

/// The iPhone shell (tab bar + mini player).
#if os(iOS)
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Namespace private var nowPlayingTransition

    /// The mini player is attached with the system `.tabViewBottomAccessory`, so the system owns
    /// its placement and the content safe-area clearance relative to the real tab bar. Apple
    /// Watch transfer status is never shown here (My Music's "On My Watch" section owns it
    /// instead) — the accessory is sized for exactly one row, and the system API does not expect
    /// a dynamically-two-row-tall accessory view.
    private var chrome: FindSearchChromeState {
        FindSearchChromeState(
            isFindActive: appState.tab == .find,
            isQueryFocused: appState.findQueryFocused,
            hasCurrentTrack: player.currentTrack != nil,
            isNowPlayingPresented: appState.showNowPlaying,
            isListenActive: appState.tab == .listen,
            showsListenContinue: player.continueListeningPresentation != nil)
    }

    private var accessoryHeight: CGFloat { chrome.accessoryHeight }

    var body: some View {
        ZStack(alignment: .bottom) {
            backgroundLayer.ignoresSafeArea()

            rootTabs

            AppStatusBanners()
        }
        .toastLayer(bottomInset: 96)
        .tint(Palette.accent)
        .modifier(AppPresentations())
        .onChange(of: appState.tab) { _, tab in
            if tab != .find { appState.findQueryFocused = false }
        }
    }

    @ViewBuilder
    private var rootTabs: some View {
        baseTabs
            .environment(\.rootTabNowPlayingNamespace, nowPlayingTransition)
            .sensoryFeedback(.selection, trigger: appState.tab)
    }

    @ViewBuilder
    private var baseTabs: some View {
        if #available(iOS 26.1, *) {
            tabs.tabViewBottomAccessory(isEnabled: accessoryHeight > 0) { tabAccessory }
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView(selection: $appState.tab) {
            NavigationStack {
                ListenView()
                    .rootTabChrome(.listen)
            }
                .tabItem { Label("Listen", systemImage: "play.circle.fill") }
                .tag(AppTab.listen)
            MyMusicView()
                .tabItem { Label("My Music", systemImage: "music.note.list") }
                .tag(AppTab.myMusic)
            FindView()
                .tabItem { Label("Find", systemImage: "magnifyingglass") }
                .tag(AppTab.find)
        }
    }

    @ViewBuilder
    private var tabAccessory: some View {
        if chrome.showsMiniPlayer {
            MiniPlayerAccessory(transitionNamespace: nowPlayingTransition)
                // Recreate the accessory when a playlist tap replaces an
                // existing queue item so SwiftUI cannot retain an empty
                // accessory subtree during the navigation transition.
                .id(player.currentTrack?.id ?? -1)
        }
    }

    private var backgroundLayer: some View {
        Palette.libraryBackground
    }
}

#endif

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
