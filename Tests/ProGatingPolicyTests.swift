import XCTest

@testable import Tonearm

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

    func testArchiveSourcesAreNotRemoteLibraryProFeatures() {
        XCTAssertEqual(RemoteLibraryAccessPolicy.decision(for: .browse(.iaItem), isPro: false), .allow)
        XCTAssertEqual(RemoteLibraryAccessPolicy.decision(for: .browse(.iaCollection), isPro: false), .allow)
        XCTAssertEqual(RemoteLibraryAccessPolicy.decision(for: .browse(.local), isPro: false), .allow)
    }

    func testToolsPolicyMapsToolsToPaidFeatures() {
        XCTAssertEqual(ProToolsAccessPolicy.decision(for: .smartPlaylist, isPro: false), .requiresPro(.smartPlaylists))
        XCTAssertEqual(ProToolsAccessPolicy.decision(for: .tagEditor, isPro: false), .requiresPro(.tagEditor))
        XCTAssertEqual(ProToolsAccessPolicy.decision(for: .parametricEQ, isPro: false), .requiresPro(.proAudioTools))
        XCTAssertEqual(ProToolsAccessPolicy.decision(for: .crossfeed, isPro: true), .allow)
    }

    func testAddRemoteLibraryEntryPointPresentsPaywallWhenNotPro() throws {
        let appState = AppState(store: try LibraryStore(inMemory: true))

        appState.requestAddRemoteLibrary()

        XCTAssertTrue(appState.showProPaywall)
        XCTAssertFalse(appState.showAddRemoteLibrary)
    }

    func testAddRemoteLibraryEntryPointOpensSheetWhenPro() throws {
        ProEntitlement.persist(ProEntitlement.verified(transactionID: 42, purchaseDate: Date()))
        let appState = AppState(store: try LibraryStore(inMemory: true))

        appState.requestAddRemoteLibrary()

        XCTAssertFalse(appState.showProPaywall)
        XCTAssertTrue(appState.showAddRemoteLibrary)
    }

    func testAppStateRemoteMethodsGateBeforeProviderWork() async throws {
        let appState = AppState(store: try LibraryStore(inMemory: true))
        let source = Source(
            id: 1,
            kind: .webDAV,
            iaIdentifier: "alice",
            originalURL: "https://dav.example.com",
            title: "DAV",
            addedAt: Date(),
            lastResolvedAt: nil,
            followUpdates: false,
            licenseText: nil,
            memberCapHit: false
        )

        do {
            _ = try await appState.browseRemote(source: source, path: "")
            XCTFail("Expected browseRemote to require Pro")
        } catch {
            XCTAssertEqual(error as? ProFeatureAccessError, .requiresPro(.remoteLibraries))
        }

        do {
            try await appState.addSubsonicServer(url: "not a url", username: "alice", password: "secret")
            XCTFail("Expected addSubsonicServer to require Pro before URL validation")
        } catch {
            XCTAssertEqual(error as? ProFeatureAccessError, .requiresPro(.remoteLibraries))
        }
    }
}
