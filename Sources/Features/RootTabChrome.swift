import SwiftUI

#if os(iOS)
private struct RootTabAccessoryHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct RootTabNowPlayingNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var rootTabAccessoryHeight: CGFloat {
        get { self[RootTabAccessoryHeightKey.self] }
        set { self[RootTabAccessoryHeightKey.self] = newValue }
    }

    var rootTabNowPlayingNamespace: Namespace.ID? {
        get { self[RootTabNowPlayingNamespaceKey.self] }
        set { self[RootTabNowPlayingNamespaceKey.self] = newValue }
    }
}

/// Applied INSIDE each root tab's own `NavigationStack`: the mini-player
/// clearance inset and the shared Now Playing destination. The destination is
/// bound per tab (`showNowPlaying && tab == this tab`) because inactive
/// `TabView` children stay alive; this keeps exactly one active tab pushing it.
private struct RootTabChrome: ViewModifier {
    @EnvironmentObject var appState: AppState
    @Environment(\.rootTabAccessoryHeight) private var accessoryHeight
    @Environment(\.rootTabNowPlayingNamespace) private var namespace
    let tab: AppTab
    /// When the tab's stack has an explicit path (Libraries), Now Playing is pushed onto that
    /// same path instead of a separate item-driven destination, so dismissing it pops exactly
    /// one entry and never disturbs the folder/source entries beneath it.
    var path: Binding<NavigationPath>?
    @State private var pushedNowPlaying = false
    @State private var depthBeforeNowPlaying = 0

    /// `.navigationDestination(isPresented:)`, re-derived independently inside each tab's own
    /// `NavigationStack` from one shared `Bool`, is the exact class of SwiftUI boolean-driven-
    /// presentation fragility `SettingsView.swift` already diagnosed and fixed once for a sheet
    /// ("only some of them reliably present... a single `.sheet(item:)` bound to one optional
    /// value doesn't have this failure mode"). `AppTab?` as the item is the equivalent fix here —
    /// nil when not showing in this tab's stack, this tab's own case when it is.
    private var nowPlayingItem: Binding<AppTab?> {
        Binding(
            get: { (appState.showNowPlaying && appState.tab == tab) ? tab : nil },
            set: { showing in
                if showing == nil { appState.showNowPlaying = false }
            })
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let inset = content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: accessoryHeight).allowsHitTesting(false)
            }
        if let path {
            inset
                .navigationDestination(for: NowPlayingRoute.self) { _ in
                    NowPlayingView()
                        .modifier(NowPlayingZoom(namespace: namespace))
                }
                .onChange(of: appState.showNowPlaying) { _, showing in
                    if showing, appState.tab == tab, !pushedNowPlaying {
                        depthBeforeNowPlaying = path.wrappedValue.count
                        pushedNowPlaying = true
                        path.wrappedValue.append(NowPlayingRoute())
                    } else if !showing, pushedNowPlaying {
                        pushedNowPlaying = false
                        if path.wrappedValue.count > depthBeforeNowPlaying {
                            path.wrappedValue.removeLast()
                        }
                    }
                }
                .onChange(of: path.wrappedValue.count) { _, count in
                    // Back button popped Now Playing: sync the shared flag.
                    if pushedNowPlaying, count <= depthBeforeNowPlaying {
                        pushedNowPlaying = false
                        appState.showNowPlaying = false
                    }
                }
        } else {
            inset
                .navigationDestination(item: nowPlayingItem) { _ in
                    NowPlayingView()
                        .modifier(NowPlayingZoom(namespace: namespace))
                }
        }
    }
}

private struct NowPlayingRoute: Hashable {}

private struct NowPlayingZoom: ViewModifier {
    let namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.navigationTransition(.zoom(sourceID: "now-playing", in: namespace))
        } else {
            content
        }
    }
}

extension View {
    func rootTabChrome(_ tab: AppTab, path: Binding<NavigationPath>? = nil) -> some View {
        modifier(RootTabChrome(tab: tab, path: path))
    }
}
#else
extension View {
    func rootTabChrome(_ tab: AppTab, path: Binding<NavigationPath>? = nil) -> some View { self }
}
#endif
