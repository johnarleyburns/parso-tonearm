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

    /// Real report: taps on the floating mini-player bar were often landing on whatever scroll
    /// content sat underneath it instead. Root cause: this value is what every tab reserves as
    /// bottom clearance for the accessory (`RootTabChrome.swift`'s `safeAreaInset`), but it didn't
    /// match the accessory's REAL footprint below — the accessory is placed with
    /// `.padding(.bottom, 58)` (see `body`, just below), so its visible bar spans from 58pt up to
    /// `58 + content height` above the absolute bottom. The old `+ 12` tail here reserved far less
    /// than that real `58`, leaving a real gap where scrollable content could sit directly behind
    /// the visible, supposedly-on-top bar — SwiftUI's `zIndex` governs paint order, not whether a
    /// `UIHostingController`-hosted `TabView`'s own content can still receive a touch that lands
    /// in that unreserved gap. The tail here must equal that same `58` exactly, not a smaller,
    /// separately-guessed number.
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

            if accessoryHeight > 0 {
                tabAccessory
                    .padding(.horizontal, 12)
                    // Keep the accessory above the tab bar while remaining
                    // inside the root ZStack. SwiftUI's tab accessory and
                    // safe-area inset can both disappear during a playlist
                    // detail replacement even though playback is active.
                    .padding(.bottom, 58)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
            }

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
            .environment(\.rootTabAccessoryHeight, accessoryHeight)
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
