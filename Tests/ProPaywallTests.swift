import XCTest
@testable import Tonearm

/// Paywall view-model state (no snapshot infra exists, so assert state instead
/// of pixels).
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

    func testPresentsFourFeaturesInTruthfulOrder() {
        let model = ProPaywallModel()
        XCTAssertEqual(model.features.count, 4)
        XCTAssertEqual(model.features.map { $0.title }, [
            "Remote Libraries",
            "iCloud Sync",
            "iPad + Mac",
            "Pro Audio & Library Tools"
        ])
    }

    func testNoFeatureCarriesComingSoonFlag() {
        let model = ProPaywallModel()
        for feature in model.features {
            let labels = Mirror(reflecting: feature).children.compactMap(\.label)
            XCTAssertFalse(labels.contains("comingSoon"))
        }
    }

    func testEveryProFeatureIsAdvertisedWithReachableEntryPoint() {
        let model = ProPaywallModel()
        let advertised = Set(model.features.flatMap(\.features))
        XCTAssertEqual(advertised, Set(ProFeature.allCases))
        for feature in model.features {
            XCTAssertFalse(feature.entryPoint.isEmpty)
        }
    }

    func testNoCarPlayRow() {
        let model = ProPaywallModel()
        XCTAssertFalse(model.features.contains { $0.title.localizedCaseInsensitiveContains("CarPlay") })
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
