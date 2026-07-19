import XCTest

@testable import TonearmCore

@MainActor
final class ProGatingPolicyTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ProEntitlement.clear()
    }

    override func tearDown() {
        ProEntitlement.clear()
        super.tearDown()
    }

    func testRemoteLibrariesRequireProForEveryProductProvider() {
        for kind in RemoteLibraryAccessPolicy.productSourceKinds {
            XCTAssertEqual(
                RemoteLibraryAccessPolicy.decision(for: .connect(kind), isPro: false),
                .requiresPro(.remoteLibraries)
            )
            XCTAssertEqual(
                RemoteLibraryAccessPolicy.decision(for: .browse(kind), isPro: false),
                .requiresPro(.remoteLibraries)
            )
            XCTAssertEqual(
                RemoteLibraryAccessPolicy.decision(for: .resolve(kind), isPro: false),
                .requiresPro(.remoteLibraries)
            )
        }
    }

    func testRemoteLibrariesAllowEveryProductProviderWhenPro() {
        for kind in RemoteLibraryAccessPolicy.productSourceKinds {
            XCTAssertEqual(RemoteLibraryAccessPolicy.decision(for: .connect(kind), isPro: true), .allow)
            XCTAssertEqual(RemoteLibraryAccessPolicy.decision(for: .browse(kind), isPro: true), .allow)
            XCTAssertEqual(RemoteLibraryAccessPolicy.decision(for: .resolve(kind), isPro: true), .allow)
        }
    }

    func testArchiveSourcesRequirePro() {
        XCTAssertEqual(RemoteLibraryAccessPolicy.decision(for: .browse(.iaItem), isPro: false), .requiresPro(.remoteLibraries))
        XCTAssertEqual(RemoteLibraryAccessPolicy.decision(for: .browse(.iaCollection), isPro: false), .requiresPro(.remoteLibraries))
        XCTAssertEqual(RemoteLibraryAccessPolicy.decision(for: .browse(.local), isPro: false), .allow)
    }

    func testAddRemoteLibraryEntryPointPresentsPaywallWhenNotPro() {
        XCTAssertEqual(
            RemoteLibraryGate.entryPointDecision(isPro: false),
            .showPaywall
        )
    }

    func testAddRemoteLibraryEntryPointOpensSheetWhenPro() {
        ProEntitlement.persist(ProEntitlement.verified(transactionID: 42, purchaseDate: Date()))

        XCTAssertEqual(
            RemoteLibraryGate.entryPointDecision(isPro: ProGating.isEnabled(.remoteLibraries)),
            .openSheet
        )
    }

    func testRemoteGateThrowsBeforeProviderWork() {
        do {
            try RemoteLibraryGate.require(.browse(.webDAV), isPro: false)
            XCTFail("Expected browse to require Pro")
        } catch {
            XCTAssertEqual(error as? ProFeatureAccessError, .requiresPro(.remoteLibraries))
        }

        do {
            try RemoteLibraryGate.require(.connect(.subsonic), isPro: false)
            XCTFail("Expected connect to require Pro")
        } catch {
            XCTAssertEqual(error as? ProFeatureAccessError, .requiresPro(.remoteLibraries))
        }
    }
}
