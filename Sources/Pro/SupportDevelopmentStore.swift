import Foundation
import StoreKit

/// Business decision (2026-09): Tonearm has no gated Pro features (see
/// `current_status.md`). The only purchase left is this one, purely optional,
/// one-time StoreKit **consumable** — "Contribute to Development". A
/// successful purchase does not unlock anything; it only flips the permanent
/// `isSupporter` flag that the home view's badge reads.
///
/// This file lives in `Sources/Pro/` because it is one of the two places the
/// StoreKit import boundary (`scripts/check-ci-guards.sh`'s "StoreKit import
/// boundary" guard) permits `import StoreKit` — the other being
/// `Sources/Features/Settings/ProPaywallView.swift`.
@MainActor
public final class SupportDevelopmentStore: ObservableObject {
    public static let shared = SupportDevelopmentStore()

    /// The one-time consumable. Consumables never appear in
    /// `Transaction.currentEntitlements` — StoreKit forgets them once the
    /// transaction is finished — so unlike `EntitlementStore` there
    /// is nothing to re-derive from at launch. The persisted flag below is the
    /// only record that the purchase happened, and it is never reset: a
    /// refund does not "revoke" it, because it never unlocked anything to
    /// revoke (business decision above).
    public static let productID = "guru.parso.tonearm.support.dev"

    private static let supporterDefaultsKey = "supporter.isSupporter"

    /// Whether this Apple Account has ever completed the contribution. Read
    /// once at init from `UserDefaults` — the same offline-forever shape as
    /// `ProEntitlement.isActive` — and only ever set, never cleared.
    @Published public private(set) var isSupporter: Bool

    /// What the App Store says this product is and costs, once asked, or nil
    /// while unanswered/unavailable. Never a hardcoded price — see
    /// `EntitlementStore.product`'s doc comment for why.
    @Published public private(set) var product: Product?
    @Published public private(set) var purchasing = false
    @Published public private(set) var didAttemptProductLoad = false

    private var updatesTask: Task<Void, Never>?

    private init() {
        isSupporter = UserDefaults.standard.bool(forKey: Self.supporterDefaultsKey)
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
        product = try? await Product.products(for: [Self.productID]).first
        didAttemptProductLoad = true
    }

    /// StoreKit's own localised price, or an honest placeholder until it
    /// answers — never a hardcoded "$9.99" (the same reasoning as
    /// `EntitlementStore.product`).
    public var displayPrice: String { product?.displayPrice ?? "—" }

    /// Whether the App Store is actually offering the product right now.
    public var isPurchaseAvailable: Bool { product != nil }

    /// Initiates the one-time, optional purchase. Returns whether it was
    /// verified. Never gates anything on the result — the caller only shows a
    /// thank-you and the Supporter badge appears.
    @discardableResult
    public func purchase() async -> Bool {
        var resolved = product
        if resolved == nil {
            resolved = try? await Product.products(for: [Self.productID]).first
        }
        guard let product = resolved else { return false }
        purchasing = true
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                return await handle(verification)
            case .userCancelled, .pending:
                return false
            @unknown default:
                return false
            }
        } catch {
            return false
        }
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
        UserDefaults.standard.set(true, forKey: Self.supporterDefaultsKey)
    }
}
