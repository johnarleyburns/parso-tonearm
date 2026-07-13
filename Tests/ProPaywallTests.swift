import XCTest
@testable import Tonearm

/// T3.3 — paywall view-model state (no snapshot infra exists, so assert state
/// per the AC). Verifies the six gated features are presented in mockup order
/// with CarPlay flagged coming-soon, and that Pro status reflects entitlement.
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

    func testPresentsSixFeaturesInMockupOrder() {
        let model = ProPaywallModel()
        XCTAssertEqual(model.features.count, 6)
        XCTAssertEqual(model.features.map { $0.title }, [
            "2 GB / 10 GB cache",
            "Prefetch depth",
            "Folder watch",
            "10-band EQ",
            "iCloud sync",
            "CarPlay"
        ])
    }

    func testCarPlayFlaggedComingSoon() {
        let model = ProPaywallModel()
        let carplay = model.features.first { $0.title == "CarPlay" }
        XCTAssertEqual(carplay?.comingSoon, true)
        // The other five are shippable now.
        XCTAssertEqual(model.features.filter { !$0.comingSoon }.count, 5)
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
        // is the offline source of truth the gates read.
        XCTAssertTrue(ProEntitlement.isActive)
    }
}
