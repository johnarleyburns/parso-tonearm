import SwiftUI
import TonearmCore

/// The iPhone shell (tab bar + mini player).
#if os(iOS)
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var player: AudioPlayer
    @Namespace private var nowPlayingTransition
    @State private var transferBannerDismissed = false

    private var showsTransferBanner: Bool {
        appState.watchManagement.banner != nil && !transferBannerDismissed
    }

    /// The mini player is attached with the system `.tabViewBottomAccessory`, so the system owns
    /// its placement and the content safe-area clearance relative to the real tab bar.
    private var chrome: FindSearchChromeState {
        FindSearchChromeState(
            isFindActive: appState.tab == .find,
            isQueryFocused: appState.findQueryFocused,
            hasCurrentTrack: player.currentTrack != nil,
            hasTransferBanner: showsTransferBanner,
            isNowPlayingPresented: appState.showNowPlaying,
            isMoodActive: appState.tab == .mood,
            isMoodPromptFocused: appState.moodPromptFocused)
    }

    private var accessoryHeight: CGFloat { chrome.accessoryHeight }

    var body: some View {
        ZStack(alignment: .bottom) {
            backgroundLayer.ignoresSafeArea()

            rootTabs

            AppStatusBanners()
        }
        .toastLayer(bottomInset: 96)
        .task { await announceWatchConnection() }
        .tint(Palette.accent)
        .modifier(AppPresentations())
        .onChange(of: appState.tab) { _, tab in
            if tab != .find { appState.findQueryFocused = false }
            if tab != .mood { appState.moodPromptFocused = false }
        }
        .onChange(of: appState.watchManagement.banner == nil) { _, empty in
            if empty { transferBannerDismissed = false }
        }
    }

    // MARK: - Apple Watch connection toast

    /// On launch, if a watch is paired, say we're connecting, then resolve to "Connected" or
    /// "not reachable" once the session settles. Skipped in UI tests.
    private func announceWatchConnection() async {
        guard !ProcessInfo.processInfo.arguments.contains("UI_TESTING") else { return }
        guard appState.watchSessionState == .installedNotReachable
                || appState.watchSessionState == .reachable else { return }

        ToastCenter.shared.progress("Connecting to Apple Watch…", icon: "applewatch", tag: "watch.link")
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if appState.watchSessionState == .reachable {
                ToastCenter.shared.success("Connected to Apple Watch", icon: "applewatch", tag: "watch.link")
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        ToastCenter.shared.info("Apple Watch not reachable", icon: "applewatch.slash", tag: "watch.link")
    }

    @ViewBuilder
    private var rootTabs: some View {
        baseTabs
            .environment(\.rootTabNowPlayingNamespace, nowPlayingTransition)
            .sensoryFeedback(.selection, trigger: appState.tab)
    }

    private var baseTabs: some View {
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
            NavigationStack {
                MoodView()
                    .rootTabChrome(.mood)
            }
                .tabItem { Label("Mood", systemImage: "sparkles") }
                .tag(AppTab.mood)
            SourcesView()
                .tabItem { Label("Libraries", systemImage: "externaldrive.connected.to.line.below") }
                .tag(AppTab.libraries)
            FindView()
                .tabItem { Label("Find", systemImage: "magnifyingglass") }
                .tag(AppTab.find)
        }
        .tabViewBottomAccessory(isEnabled: accessoryHeight > 0) { tabAccessory }
    }

    @ViewBuilder
    private var tabAccessory: some View {
        VStack(spacing: 4) {
            if chrome.showsTransferBanner {
                TransferPill { transferBannerDismissed = true }
            }
            if chrome.showsMiniPlayer {
                MiniPlayerAccessory(transitionNamespace: nowPlayingTransition)
                    // Recreate the accessory when a playlist tap replaces an
                    // existing queue item so SwiftUI cannot retain an empty
                    // accessory subtree during the navigation transition.
                    .id(player.currentTrack?.id ?? -1)
            }
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
