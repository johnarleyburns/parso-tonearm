import Foundation
import StoreKit

/// Injection seam for tests. StoreKit's `Product`/`Transaction` have no public initializer
/// outside Apple's simulator-only `StoreKitTest` framework (and that needs an Xcode scheme with
/// a `.storekit` config attached), so `SupportDevelopmentStore`'s purchase/load business logic
/// had never been exercised by a test at all. This speaks in the store's own vocabulary — a
/// display price string and a purchase-succeeded bool — instead of StoreKit's types.
public protocol SupportDevelopmentPurchasing: Sendable {
    /// The product's localized display price, or nil if unavailable.
    func loadProduct() async -> String?
    /// Whether a verified purchase transaction completed.
    func purchase() async -> Bool
}

/// The real StoreKit-backed implementation. Kept in this same file so the StoreKit import
/// boundary guard (`scripts/check-ci-guards.sh`) still only ever sees `import StoreKit` here.
/// `public` (and an explicit `public init()`) because it's referenced as a default argument
/// value in `SupportDevelopmentStore`'s own `public init` — a default argument must be at least
/// as visible as the initializer it belongs to.
public struct LiveSupportDevelopmentPurchasing: SupportDevelopmentPurchasing {
    public init() {}

    public func loadProduct() async -> String? {
        let product = try? await Product.products(for: [SupportDevelopmentStore.productID]).first
        return product?.displayPrice
    }

    public func purchase() async -> Bool {
        guard let product = try? await Product.products(for: [SupportDevelopmentStore.productID]).first
        else { return false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { return false }
                guard transaction.productID == SupportDevelopmentStore.productID else {
                    // Not our product — finish it anyway so it does not linger as an
                    // unfinished transaction forever, but this call did not earn it.
                    await transaction.finish()
                    return false
                }
                // Consumables must be finished for StoreKit to consider them delivered;
                // unlike the Pro non-consumable, there is no entitlement for a re-launch
                // to re-derive, so finishing is the only step here.
                await transaction.finish()
                return true
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            return false
        }
    }
}

/// Business decision (2026-09): Tonearm has no gated Pro features (see
/// `current_status.md`). The only purchase left is this one, purely optional,
/// one-time StoreKit **consumable** — "Contribute to Development". A
/// successful purchase does not unlock anything; it only flips the permanent
/// `isSupporter` flag that the home view's badge reads.
///
/// This file lives in `Sources/Support/` because it is the one place the
/// StoreKit import boundary (`scripts/check-ci-guards.sh`'s "StoreKit import
/// boundary" guard) permits `import StoreKit` — there is no longer a Pro
/// entitlement/paywall to carve a second exception for.
@MainActor
public final class SupportDevelopmentStore: ObservableObject {
    public static let shared = SupportDevelopmentStore()

    /// The one-time consumable. Consumables never appear in
    /// `Transaction.currentEntitlements` — StoreKit forgets them once the
    /// transaction is finished — so unlike a non-consumable entitlement there
    /// is nothing to re-derive from at launch. The persisted flag below is the
    /// only record that the purchase happened, and it is never reset: a
    /// refund does not "revoke" it, because it never unlocked anything to
    /// revoke (business decision above).
    public static let productID = "guru.parso.tonearm.support.dev"

    private static let supporterDefaultsKey = "supporter.isSupporter"

    /// Whether this Apple Account has ever completed the contribution. Read
    /// once at init from `UserDefaults`, offline-forever — and only ever set,
    /// never cleared.
    @Published public private(set) var isSupporter: Bool

    @Published public private(set) var purchasing = false
    @Published public private(set) var didAttemptProductLoad = false
    /// What the App Store says this product costs, once asked, or nil while unanswered/
    /// unavailable. Never a hardcoded price — see `displayPrice`'s own doc.
    @Published private var loadedDisplayPrice: String?

    private let defaults: UserDefaults
    private let purchasing_: SupportDevelopmentPurchasing
    private var updatesTask: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard,
                purchasing: SupportDevelopmentPurchasing = LiveSupportDevelopmentPurchasing()) {
        self.defaults = defaults
        self.purchasing_ = purchasing
        isSupporter = defaults.bool(forKey: Self.supporterDefaultsKey)
    }

    /// Begins observing `Transaction.updates` (a consumable purchased on
    /// another device under the same Apple Account can still arrive here) and
    /// loads the product. Call once at launch.
    public func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { [weak self] in await self?.loadProduct() }
    }

    /// Ask the App Store what this product is and costs, right now. Safe to
    /// call repeatedly — the settings card calls it on appear.
    public func loadProduct() async {
        loadedDisplayPrice = await purchasing_.loadProduct()
        didAttemptProductLoad = true
    }

    /// StoreKit's own localised price, or an honest placeholder until it
    /// answers — never a hardcoded "$9.99" (the same reasoning as
    /// above).
    public var displayPrice: String { loadedDisplayPrice ?? "—" }

    /// Whether the App Store is actually offering the product right now.
    public var isPurchaseAvailable: Bool { loadedDisplayPrice != nil }

    /// Initiates the one-time, optional purchase. Returns whether it was
    /// verified. Never gates anything on the result — the caller only shows a
    /// thank-you and the Supporter badge appears.
    @discardableResult
    public func purchase() async -> Bool {
        purchasing = true
        defer { purchasing = false }
        let ok = await purchasing_.purchase()
        if ok { markSupporter() }
        return ok
    }

    // MARK: - Verification

    @discardableResult
    private func handle(_ verification: VerificationResult<Transaction>) async -> Bool {
        guard case .verified(let transaction) = verification else { return false }
        guard transaction.productID == Self.productID else {
            // Not our product — finish it anyway so it does not linger as an
            // unfinished transaction forever, but this call did not earn it.
            await transaction.finish()
            return false
        }
        markSupporter()
        // Consumables must be finished for StoreKit to consider them
        // delivered; unlike the Pro non-consumable, there is no entitlement
        // for a re-launch to re-derive, so finishing is the only step here.
        await transaction.finish()
        return true
    }

    /// Sets the persisted flag. Idempotent, and — per the business decision —
    /// there is no code path that ever clears it.
    private func markSupporter() {
        guard !isSupporter else { return }
        isSupporter = true
        defaults.set(true, forKey: Self.supporterDefaultsKey)
    }
}
