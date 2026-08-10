import XCTest
@testable import TonearmCore

/// AT-STORE-4 — every row of the Founders-grant decision table (Appendix T.4),
/// pinned as a pure unit test so a grant regression is caught without needing a
/// live StoreKit configuration.
///
/// Rows under test:
///  1. Owns retired product, has not bought DJ        → grant, `.foundersGrant`
///  2. Owns retired product AND bought DJ             → grant, `.purchased` (refund path is UI)
///  3. Owns retired product via Family Sharing        → grant, `.foundersGrant`
///  4. Refunded the retired product                   → no grant
///  5. New user, never bought anything                → no grant
///  6. Restores on a new device years later           → grant re-derives (row 1 again)
///
/// Ambiguity resolves toward granting: an unverified transaction for the
/// retired product still counts as owning it.
final class FoundersGrantTests: XCTestCase {

    private let retired = FoundersGrant.retiredProductID
    private let dj = FoundersGrant.djProductID

    private func fact(_ productID: String,
                      verified: Bool = true,
                      revoked: Bool = false,
                      familyShared: Bool = false) -> TransactionFact {
        TransactionFact(productID: productID,
                        isVerified: verified,
                        isRevoked: revoked,
                        isFamilyShared: familyShared)
    }

    // Row 1
    func testRow1OwnsRetiredProductGrantsFounders() {
        let ownership = FoundersGrant.ownership(from: [fact(retired)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .foundersGrant)
    }

    // Row 2 — bought both: granted via the purchase; the refund path is a UI
    // concern, not an entitlement decision.
    func testRow2OwnsRetiredAndBoughtDJPurchased() {
        let ownership = FoundersGrant.ownership(from: [fact(retired), fact(dj)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .purchased)
    }

    // Row 3
    func testRow3FamilySharedRetiredGrantsFounders() {
        let ownership = FoundersGrant.ownership(from: [fact(retired, familyShared: true)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .foundersGrant)
    }

    // Row 4 — a revoked transaction is not owned, so no row grants.
    func testRow4RefundedRetiredGrantsNothing() {
        let ownership = FoundersGrant.ownership(from: [fact(retired, revoked: true)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .none)
    }

    // Row 5
    func testRow5NewUserGrantsNothing() {
        let ownership = FoundersGrant.ownership(from: [])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .none)
    }

    // Row 6 — restore re-derives from currentEntitlements; nothing is stored
    // server-side. The same pure decision as row 1, computed fresh.
    func testRow6RestoreOnNewDeviceReDerives() {
        let ownership = FoundersGrant.ownership(from: [fact(retired)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .foundersGrant)
    }

    // Refunded retired product AND bought DJ: the DJ purchase still grants.
    func testRefundedRetiredButOwnsDJStillGrants() {
        let ownership = FoundersGrant.ownership(from: [fact(retired, revoked: true), fact(dj)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .purchased)
    }

    // Ambiguity resolves toward granting (T.4): an unverified retired-product
    // transaction still counts as owning it.
    func testUnverifiedRetiredStillGrants() {
        let ownership = FoundersGrant.ownership(from: [fact(retired, verified: false)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .foundersGrant)
    }

    // Ambiguity does NOT extend to the DJ product — an unverified DJ purchase
    // is not a plausible grant.
    func testUnverifiedDJPurchaseDoesNotGrant() {
        let ownership = FoundersGrant.ownership(from: [fact(dj, verified: false)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .none)
    }

    // Family-shared DJ purchase is a distinct source.
    func testFamilySharedDJIsFamilySharedSource() {
        let ownership = FoundersGrant.ownership(from: [fact(dj, familyShared: true)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .familyShared)
    }

    // Unrelated products are ignored.
    func testUnrelatedProductsAreIgnored() {
        let ownership = FoundersGrant.ownership(from: [
            TransactionFact(productID: "guru.parso.other", isVerified: true, isRevoked: false, isFamilyShared: false),
        ])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .none)
    }
}
