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
                detail: "Connect to all 9 providers: \(RemoteConnectorCatalog.proDisplayList)",
                features: [.remoteLibraries],
                entryPoint: "Settings > Libraries")
    ]

    public func refresh() {
        isPro = store.isPro
        displayPrice = store.displayPrice
    }

    @discardableResult
    public func purchase() async -> Bool {
        purchasing = true
        let success = await store.purchase()
        purchasing = false
        refresh()
        return success && isPro
    }

    @discardableResult
    public func restore() async -> Bool {
        await store.restore()
        refresh()
        return isPro
    }
}
