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

    /// The price shown before the store has answered — and **only** then.
    ///
    /// It used to be the price, full stop, on the reasoning that the paywall
    /// cannot import StoreKit. That was the wrong conclusion from a correct
    /// premise: the price is localised and lives in App Store Connect, so a
    /// constant here is wrong in every non-US storefront the day it ships and
    /// wrong everywhere the moment the price changes. The boundary is kept —
    /// `StoreProduct` carries the already-formatted string across it — and this
    /// is now only a placeholder for the moment before the answer arrives.
    public static let placeholderPrice = "—"

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

    /// The real, localised price once the store has answered; the placeholder
    /// until then.
    public var displayPrice: String { store.product?.displayPrice ?? Self.placeholderPrice }

    /// Whether the App Store is actually offering this product right now.
    ///
    /// False means the store was asked and could not answer — an App Store
    /// Connect product that is missing, not yet approved, or not sold in this
    /// storefront, or a device with no network. The sheet must then say so and
    /// **not** offer a Buy button: a button that cannot work makes the user
    /// think they did something wrong, and on a fresh TestFlight build with an
    /// unconfigured product it is the single most likely thing a tester meets.
    public var isPurchaseAvailable: Bool { store.product != nil }

    /// True only once the store has been asked and has failed to answer — the
    /// state that earns the honest message, as distinct from "still loading".
    public var isStoreUnavailable: Bool {
        store.didAttemptProductLoad && store.product == nil
    }

    /// Ask the store for the product. Called when the sheet appears, so a user
    /// who launched offline still sees a real price when they open it.
    public func loadProduct() async {
        await store.refreshProduct()
        objectWillChange.send()
    }

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
    ///
    /// A restore that finds nothing must **say** so. Silence after tapping
    /// Restore is indistinguishable from a broken button, and the user's next
    /// move is to buy something they may already own.
    public func restore() async {
        lastError = nil
        isRestoring = true
        defer { isRestoring = false }
        await store.restore()
        refreshPro()
        if !isPro {
            lastError = "No previous purchase was found on this Apple Account."
        }
    }

    @Published public private(set) var isRestoring = false

    private func refreshPro() {
        isPro = store.isPro
        if isPro { isPresented = false }
    }
}
