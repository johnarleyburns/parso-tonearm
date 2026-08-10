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

    /// The Pro features shown on the sheet, in mockup order. The paywall is
    /// unpresented until M4 repurposes it for the DJ product, so the honest
    /// list is empty. `ProCapability` (Appendix T.3) is the capability set the
    /// next milestone's paywall will advertise.
    public struct Feature: Identifiable {
        public var id: String { title }
        public let title: String
        public let detail: String
        public let features: [ProCapability]
        public let entryPoint: String

        public init(title: String, detail: String, features: [ProCapability], entryPoint: String) {
            self.title = title
            self.detail = detail
            self.features = features
            self.entryPoint = entryPoint
        }
    }

    public var features: [Feature] = []

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
