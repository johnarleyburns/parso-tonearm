import XCTest
@testable import TonearmCore

/// AT-STORE-4 — the Founders-grant decision table (Appendix T.4), **one row**
/// after M4 decision 1 (plan §2.1): with the retired remote-libraries product
/// repurposed in place, `guru.parso.tonearm.pro` *is* the DJ product, so
/// verified ownership of it ⇒ Pro. Pinned as a pure unit test so a grant
/// regression is caught without needing a live StoreKit configuration.
///
/// Rows under test:
///  1. Verified own purchase, not revoked          → `.purchased`
///  2. Verified Family-Shared copy, not revoked    → `.familyShared`
///  3. Refunded (revoked transaction)              → no entitlement
///  4. New user, never bought anything             → no entitlement
///  5. Restores on a new device years later        → re-derives (row 1 again)
///  6. Unverified transaction                      → no entitlement (only a
///     verified fact is a plausible grant for the current product)
final class FoundersGrantTests: XCTestCase {

    private let productID = FoundersGrant.productID

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
    func testVerifiedOwnPurchaseGrantsPurchased() {
        let ownership = FoundersGrant.ownership(from: [fact(productID)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .purchased)
    }

    // Row 2
    func testFamilySharedCopyGrantsFamilyShared() {
        let ownership = FoundersGrant.ownership(from: [fact(productID, familyShared: true)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .familyShared)
    }

    // Row 3 — a revoked transaction is not owned, so no row grants.
    func testRefundedProductGrantsNothing() {
        let ownership = FoundersGrant.ownership(from: [fact(productID, revoked: true)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .none)
    }

    // Row 4
    func testNewUserGrantsNothing() {
        let ownership = FoundersGrant.ownership(from: [])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .none)
    }

    // Row 5 — restore re-derives from currentEntitlements; nothing is stored
    // server-side. The same pure decision as row 1, computed fresh.
    func testRestoreOnNewDeviceReDerives() {
        let ownership = FoundersGrant.ownership(from: [fact(productID)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .purchased)
    }

    // Row 6 — an unverified transaction for the current product is not a
    // plausible grant (generosity was scoped to the retired product, which no
    // longer exists).
    func testUnverifiedTransactionGrantsNothing() {
        let ownership = FoundersGrant.ownership(from: [fact(productID, verified: false)])
        XCTAssertEqual(FoundersGrant.outcome(for: ownership), .none)
    }

    // A refunded purchase plus a surviving family-shared copy still grants via
    // the family row.
    func testRevokedOwnPurchaseWithSurvivingFamilyCopyStillGrants() {
        let ownership = FoundersGrant.ownership(from: [
            fact(productID, revoked: true),
            fact(productID, familyShared: true),
        ])
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
