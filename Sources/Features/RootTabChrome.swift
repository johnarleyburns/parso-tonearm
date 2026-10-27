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

    private var nowPlaying: Binding<Bool> {
        Binding(
            get: { appState.showNowPlaying && appState.tab == tab },
            set: { showing in
                if !showing { appState.showNowPlaying = false }
            })
    }

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: accessoryHeight).allowsHitTesting(false)
            }
            .navigationDestination(isPresented: nowPlaying) {
                NowPlayingView()
                    .modifier(NowPlayingZoom(namespace: namespace))
            }
    }
}

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
    func rootTabChrome(_ tab: AppTab) -> some View { modifier(RootTabChrome(tab: tab)) }
}
#else
extension View {
    func rootTabChrome(_ tab: AppTab) -> some View { self }
}
#endif
