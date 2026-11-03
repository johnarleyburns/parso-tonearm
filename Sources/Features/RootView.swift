import SwiftUI
import TonearmCore
import UIKit

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

    private var accessoryHeight: CGFloat {
        guard !appState.showNowPlaying else { return 0 }
        let count = (player.currentTrack != nil ? 1 : 0) + (showsTransferBanner ? 1 : 0)
        return count == 0 ? 0 : CGFloat(count) * 56 + CGFloat(count - 1) * 4 + 12
    }

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
        .environmentObject(appState.transitionPrepService)
        .task { await announceWatchConnection() }
        .tint(Palette.accent)
        .modifier(AppPresentations())
        .onChange(of: appState.watchManagement.banner == nil) { _, empty in
            if empty { transferBannerDismissed = false }
        }
        .onChange(of: appState.tab) { old, new in
            // The DJ tab never renders inline content: selecting it presents a full-screen
            // cover instead, and the tab bar underneath keeps showing whichever tab was
            // active before (AppPresentations.swift owns the actual .fullScreenCover).
            if new == .dj {
                appState.showDJConsole = true
                appState.tab = old
            }
        }
        .onChange(of: appState.showDJConsole) { _, active in
            guard let delegate = UIApplication.shared.delegate as? TonearmAppDelegate else { return }
            delegate.landscapeLocked = active
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow }?.rootViewController }
                .first?
                .setNeedsUpdateOfSupportedInterfaceOrientations()
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
            // Never actually shown: selecting .dj is intercepted above to present a
            // full-screen cover instead, so this content is a placeholder TabView requires
            // for every tag it declares — no NavigationStack/rootTabChrome needed.
            Color.clear
                .tabItem { Label("DJ", systemImage: "slider.horizontal.3") }
                .tag(AppTab.dj)
            FindView()
                .tabItem { Label("Find", systemImage: "magnifyingglass") }
                .tag(AppTab.find)
        }
    }

    @ViewBuilder
    private var tabAccessory: some View {
        VStack(spacing: 4) {
            if showsTransferBanner {
                TransferPill { transferBannerDismissed = true }
            }
            if player.currentTrack != nil {
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
