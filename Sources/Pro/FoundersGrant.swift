import Foundation

/// Appendix T.4 — the Founders grant, **collapsed to the single product**
/// (M4 decision 1, plan §2.1). The app has never published and has no buyers,
/// so the "retired remote-libraries product" never existed in the wild:
/// `guru.parso.tonearm.pro` *is* the DJ product, repurposed in place (the
/// identifier is repo reality — never coin a new one, or every existing
/// purchase is orphaned). The decision table therefore has **one row**:
/// verified ownership of `guru.parso.tonearm.pro` ⇒ Pro, with the
/// family-shared and revoked branches that survive. Determination is from
/// `Transaction.currentEntitlements`; this file is the *pure* decision table
/// so every row is unit-testable (AT-STORE-4) without a live StoreKit
/// configuration.
///
/// **Ambiguity resolves toward granting** only within a verified fact — an
/// unverified transaction for the current product is not a plausible grant
/// (generosity was scoped to the retired product, which no longer exists).
public enum FoundersGrant {
    /// The single, repurposed product. `ProEntitlement.productID` is the same
    /// identifier — this is the one thing to buy.
    public static let productID = "guru.parso.tonearm.pro"

    /// Ownership facts the decision table needs, derived from StoreKit
    /// transactions by `EntitlementStore`.
    public struct Ownership: Equatable, Sendable {
        /// Verified purchase of the product, not revoked.
        public var ownsProduct: Bool
        /// Family-shared copy of the product, not revoked.
        public var ownsViaFamily: Bool

        public init(ownsProduct: Bool = false, ownsViaFamily: Bool = false) {
            self.ownsProduct = ownsProduct
            self.ownsViaFamily = ownsViaFamily
        }
    }

    /// Where the entitlement came from, keyed to `EntitlementStore.Source`.
    /// `.foundersGrant` no longer exists — with one product, owning it *is* a
    /// purchase.
    public enum Outcome: Equatable, Sendable {
        case none
        case purchased
        case familyShared
    }

    /// Applies the T.4 decision table — one row.
    ///
    /// | Case | Outcome |
    /// |---|---|
    /// | Verified own purchase, not revoked | `.purchased` |
    /// | Verified Family-Shared copy, not revoked | `.familyShared` |
    /// | Refunded (revoked transaction) | `.none` — a revoked transaction is not owned |
    /// | Never bought anything | `.none` |
    /// | Restores on a new device years later | re-derives from `currentEntitlements` (row 1 again) |
    public static func outcome(for ownership: Ownership) -> Outcome {
        if ownership.ownsProduct { return .purchased }
        if ownership.ownsViaFamily { return .familyShared }
        return .none
    }

    /// Derives ownership facts from StoreKit transaction facts. The DJ product
    /// requires a *verified* transaction — an unverified one is not a plausible
    /// grant; a revoked transaction is never owned, so a refund removes the
    /// entitlement.
    public static func ownership(from facts: [TransactionFact]) -> Ownership {
        var ownership = Ownership()
        for fact in facts {
            guard fact.isVerified, !fact.isRevoked, fact.productID == productID else { continue }
            if fact.isFamilyShared {
                ownership.ownsViaFamily = true
            } else {
                ownership.ownsProduct = true
            }
        }
        return ownership
    }
}
