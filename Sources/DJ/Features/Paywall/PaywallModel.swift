import Combine
import Foundation
import TonearmCore

/// The §41.16 / §42.10 paywall view model (mockups `ipad/13a`, `ipad/13b`,
/// `iphone/08`, plan 4.13). It consumes `EntitlementStore.isPro` and calls
/// `purchase()`/`restore()` — it **never imports StoreKit** (App. T.3, §6.3);
/// the StoreKit boundary stays in `Sources/Pro/`.
///
/// Presentation is **contextual** (FR-STORE-5, §40.4 rule 3): `present()` is
/// the sheet's only entry point, called when the user reaches for a Pro
/// control (taps the lock chip). Never on launch, never on a timer, never over
/// playback. A dismissal is final for the session — nothing re-presents the
/// sheet automatically (FR-STORE-6, Appendix T.7); only another explicit
/// `present()` can show it.
@MainActor
public final class PaywallModel: ObservableObject {

    /// The one-time price shown on the sheet. A constant, pinned to the single
    /// product in `Resources/Tonearm.storekit` ($39.99) — the paywall never
    /// imports StoreKit, so the price cannot be read from `Product` here.
    public static let displayPrice = "$39.99"

    @Published public private(set) var isPresented = false
    @Published public private(set) var isPurchasing = false
    @Published public private(set) var isPro: Bool
    @Published public private(set) var lastError: String?

    /// Whether the user dismissed the sheet at least once this session
    /// (FR-STORE-6's "no nagging": no repeat prompt after a dismissal).
    public private(set) var dismissedThisSession = false

    public let store: EntitlementStore

    public init(store: EntitlementStore) {
        self.store = store
        self.isPro = store.isPro
    }

    public var displayPrice: String { Self.displayPrice }

    /// §40.4 rule 3 / FR-STORE-5: the only way the sheet appears. A Pro user
    /// has nothing to buy — presenting is a no-op.
    public func present() {
        guard !isPro else { return }
        isPresented = true
    }

    /// Dismiss the sheet. Nothing re-presents it unprompted (FR-STORE-6).
    public func dismiss() {
        isPresented = false
        dismissedThisSession = true
    }

    /// Buy Platterhead DJ. A verified purchase flips `isPro` in-process — the
    /// decks unlock with no relaunch (AT-STORE-2) — and the sheet dismisses
    /// itself. A cancellation or failure leaves the sheet up with an honest
    /// message.
    public func purchase() async {
        isPurchasing = true
        lastError = nil
        defer { isPurchasing = false }
        let ok = await store.purchase()
        refreshPro()
        if ok {
            isPresented = false
        } else if !isPro {
            lastError = "The purchase did not complete. Nothing was charged — please try again."
        }
    }

    /// Restore a prior purchase via the App Store account (FR-STORE-3). If a
    /// verified entitlement exists it re-derives and the sheet dismisses.
    public func restore() async {
        lastError = nil
        await store.restore()
        refreshPro()
    }

    private func refreshPro() {
        isPro = store.isPro
        if isPro { isPresented = false }
    }
}
