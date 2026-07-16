import Combine
import Foundation

/// Testable state for the paywall so acceptance tests can assert model state
/// instead of pixels.
@MainActor
public final class ProPaywallModel: ObservableObject {
    @Published public var isPro: Bool
    @Published public var purchasing = false
    @Published public var displayPrice: String

    private let store: ProStore

    public init(store: ProStore? = nil) {
        let resolvedStore = store ?? .shared
        self.store = resolvedStore
        self.isPro = resolvedStore.isPro
        self.displayPrice = resolvedStore.displayPrice
    }

    /// The Pro features shown on the sheet, in mockup order.
    public struct Feature: Identifiable {
        public var id: String { title }
        public let title: String
        public let detail: String
        public let features: [ProFeature]
        public let entryPoint: String

        public init(title: String, detail: String, features: [ProFeature], entryPoint: String) {
            self.title = title
            self.detail = detail
            self.features = features
            self.entryPoint = entryPoint
        }
    }

    public let features: [Feature] = [
        Feature(title: "Remote Libraries",
                detail: "Subsonic, WebDAV, Jellyfin, Plex and cloud drives",
                features: [.remoteLibraries],
                entryPoint: "Settings > Sources"),
        Feature(title: "iCloud Sync",
                detail: "library, playlists, favorites, history, artwork and EQ presets",
                features: [.icloudSync],
                entryPoint: "Settings > iCloud Sync"),
        Feature(title: "iPad + Mac",
                detail: "same purchase on every device",
                features: [],
                entryPoint: "Universal purchase"),
        Feature(title: "Pro Audio & Library Tools",
                detail: "parametric EQ, crossfeed, convolution, smart playlists, tag editor and duplicate detection",
                features: [.proAudioTools, .smartPlaylists, .tagEditor],
                entryPoint: "Settings > Tools")
    ]

    public func refresh() {
        isPro = store.isPro
        displayPrice = store.displayPrice
    }

    public func purchase() async {
        purchasing = true
        _ = await store.purchase()
        purchasing = false
        refresh()
    }

    public func restore() async {
        await store.restore()
        refresh()
    }
}
