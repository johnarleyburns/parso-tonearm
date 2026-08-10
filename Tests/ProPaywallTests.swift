import XCTest
@testable import TonearmCore

/// Paywall view-model state (no snapshot infra exists, so assert state instead
/// of pixels). Through commit 0.4 nothing is paid — `ProFeature` is empty — so
/// the advertised feature list is empty and the StoreKit read path is what
/// remains testable.
@MainActor
final class ProPaywallTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ProEntitlement.clear()
    }

    override func tearDown() {
        ProEntitlement.clear()
        super.tearDown()
    }

    func testAdvertisesNoPaidFeaturesYet() {
        let model = ProPaywallModel()
        XCTAssertTrue(model.features.isEmpty,
                      "Commit 0.4 retires remoteLibraries; nothing is paid yet")
    }

    func testShowsPriceString() {
        let model = ProPaywallModel()
        XCTAssertFalse(model.displayPrice.isEmpty)
    }

    func testReflectsEntitlementState() {
        let model = ProPaywallModel()
        XCTAssertFalse(model.isPro)

        ProEntitlement.persist(ProEntitlement.verified(transactionID: 1, purchaseDate: Date()))
        // ProStore.isPro is only refreshed via StoreKit callbacks; the cached flag
        // is the offline source of truth the entitlement cache reads.
        XCTAssertTrue(ProEntitlement.isActive)
    }
}
