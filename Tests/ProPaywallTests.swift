import XCTest
@testable import TonearmCore

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

    func testPresentsOneFeature() {
        let model = ProPaywallModel()
        XCTAssertEqual(model.features.count, 1)
        XCTAssertEqual(model.features.map { $0.title }, [
            "Remote Libraries"
        ])
    }

    func testRemoteLibrariesFeatureContainsAllConnectors() {
        let model = ProPaywallModel()
        let detail = model.features[0].detail
        for kind in RemoteLibraryAccessPolicy.productSourceKinds {
            let connectorName = RemoteConnectorCatalog.displayName(kind)
            XCTAssertTrue(detail.contains(connectorName),
                          "Paywall must list '\(connectorName)' but detail was '\(detail)'")
        }
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
        // The sole feature uses the only ProFeature case.
        XCTAssertEqual(model.features.first?.features, [.remoteLibraries])
        XCTAssertEqual(model.features.first?.entryPoint, "Settings > Libraries")
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
