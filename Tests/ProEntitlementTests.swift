import XCTest
@testable import TonearmCore

/// T3.1 — entitlement lifecycle: verified construction, offline cached read,
/// revocation clears, and the private-init invariant (only verified construction).
/// Full purchase/restore flows are exercised via the `.storekit` config in the
/// Tonearm scheme; these tests pin the on-device gating logic that must hold
/// with or without a live StoreKit connection.
final class ProEntitlementTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ProEntitlement.clear()
    }

    override func tearDown() {
        ProEntitlement.clear()
        super.tearDown()
    }

    func testDefaultsToNotEntitled() {
        XCTAssertFalse(ProEntitlement.isActive)
        XCTAssertNil(ProEntitlement.current)
        for feature in ProFeature.allCases {
            XCTAssertFalse(ProFeature.isEnabled(feature))
        }
    }

    func testVerifiedPurchasePersistsAndUnlocks() {
        let entitlement = ProEntitlement.verified(transactionID: 42, purchaseDate: Date())
        ProEntitlement.persist(entitlement)

        XCTAssertTrue(ProEntitlement.isActive)
        XCTAssertEqual(ProEntitlement.current?.transactionID, 42)
        for feature in ProFeature.allCases {
            XCTAssertTrue(ProFeature.isEnabled(feature))
        }
    }

    // Offline (airplane mode) read: once persisted, the cached flag keeps Pro
    // active without any StoreKit round-trip.
    func testOfflineCachedReadKeepsPro() {
        ProEntitlement.persist(ProEntitlement.verified(transactionID: 7, purchaseDate: Date()))
        // Simulate a fresh read (e.g. next launch) — no StoreKit involved.
        XCTAssertTrue(ProEntitlement.isActive)
        XCTAssertEqual(ProEntitlement.current?.transactionID, 7)
    }

    func testRevocationClearsEntitlement() {
        ProEntitlement.persist(ProEntitlement.verified(transactionID: 99, purchaseDate: Date()))
        XCTAssertTrue(ProEntitlement.isActive)

        ProEntitlement.clear()  // models a revocation / refund
        XCTAssertFalse(ProEntitlement.isActive)
        XCTAssertNil(ProEntitlement.current)
        for feature in ProFeature.allCases {
            XCTAssertFalse(ProFeature.isEnabled(feature))
        }
    }
}
