import Foundation

/// Appendix T.4 — the Founders grant. Anyone who purchased the retired
/// remote-libraries product (`guru.parso.tonearm.pro`) receives Platterhead DJ
/// at no charge. Determination is from `Transaction.currentEntitlements`; this
/// file is the *pure* decision table so every row is unit-testable (AT-STORE-4)
/// without a live StoreKit configuration.
///
/// **Ambiguity resolves toward granting.** If verification is indeterminate for
/// a user who plausibly owned the old product, grant it. The cost of a wrong
/// grant is one unearned copy; the cost of a wrong denial is a person who paid
/// being told they did not.
public enum FoundersGrant {
    /// The retired product whose verified ownership earns the grant. Repo
    /// reality (handoff §6.1): the identifier is unchanged from the shipping
    /// app — never coin a new one.
    public static let retiredProductID = "guru.parso.tonearm.pro"

    /// The DJ product this grant and the future purchase unlock. Handoff §6.1.
    public static let djProductID = "guru.parso.tonearm.pro.dj"

    /// Ownership facts the decision table needs, derived from StoreKit
    /// transactions by `EntitlementStore`.
    public struct Ownership: Equatable, Sendable {
        /// Verified purchase of the retired product, not revoked.
        public var ownsRetiredProduct: Bool
        /// Family-shared copy of the retired product, not revoked.
        public var ownsRetiredProductViaFamily: Bool
        /// Verified purchase of the DJ product, not revoked.
        public var ownsDJProduct: Bool
        /// Family-shared copy of the DJ product, not revoked.
        public var ownsDJViaFamily: Bool

        public init(ownsRetiredProduct: Bool = false,
                    ownsRetiredProductViaFamily: Bool = false,
                    ownsDJProduct: Bool = false,
                    ownsDJViaFamily: Bool = false) {
            self.ownsRetiredProduct = ownsRetiredProduct
            self.ownsRetiredProductViaFamily = ownsRetiredProductViaFamily
            self.ownsDJProduct = ownsDJProduct
            self.ownsDJViaFamily = ownsDJViaFamily
        }
    }

    /// Where the entitlement came from, keyed to `EntitlementStore.Source`.
    public enum Outcome: Equatable, Sendable {
        case none
        case purchased
        case foundersGrant
        case familyShared
    }

    /// Applies the T.4 decision table.
    ///
    /// | Case | Outcome |
    /// |---|---|
    /// | Owns retired product, has not bought DJ | `.foundersGrant` |
    /// | Owns retired product **and** bought DJ | `.purchased` — Pro; the refund path is a UI concern, not an entitlement decision |
    /// | Owns retired product via Family Sharing | `.foundersGrant` |
    /// | Refunded the retired product | `.none` — a revoked transaction is not owned, so no row grants |
    /// | New user, never bought anything | `.none` |
    /// | Restores on a new device years later | re-derives from `currentEntitlements` (row 1 again) |
    public static func outcome(for ownership: Ownership) -> Outcome {
        if ownership.ownsDJProduct { return .purchased }
        if ownership.ownsDJViaFamily { return .familyShared }
        if ownership.ownsRetiredProduct || ownership.ownsRetiredProductViaFamily {
            return .foundersGrant
        }
        return .none
    }

    /// Derives ownership facts from StoreKit transaction facts. Ambiguity
    /// resolves toward granting (T.4): an unverified transaction for the retired
    /// product still counts as owning it, because the user plausibly owned it;
    /// a revoked transaction is never owned, so a refund removes the grant.
    public static func ownership(from facts: [TransactionFact]) -> Ownership {
        var ownership = Ownership()
        for fact in facts {
            guard !fact.isRevoked else { continue }
            switch fact.productID {
            case retiredProductID:
                if fact.isFamilyShared {
                    ownership.ownsRetiredProductViaFamily = true
                } else {
                    ownership.ownsRetiredProduct = true
                }
            case djProductID:
                // The DJ product requires a verified purchase — generosity is
                // scoped to the old product, not to an unverified new one.
                guard fact.isVerified else { continue }
                if fact.isFamilyShared {
                    ownership.ownsDJViaFamily = true
                } else {
                    ownership.ownsDJProduct = true
                }
            default:
                continue
            }
        }
        return ownership
    }
}
