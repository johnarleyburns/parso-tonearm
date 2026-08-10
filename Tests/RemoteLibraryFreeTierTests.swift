import XCTest
@testable import TonearmCore

/// Commit 0.4 removes the last purchase gate — `ProFeature.remoteLibraries`
/// (FR-LIB-7). Remote libraries are free for everyone, and
/// `RemoteLibraryAccessPolicy` no longer makes a purchase decision at all; it
/// only classifies. These tests pin that classification so every one of the ten
/// providers keeps a real code path and the free flip cannot silently drop one.
final class RemoteLibraryFreeTierTests: XCTestCase {

    func testEveryNonLocalSourceKindIsClassifiedAsRemoteLibrary() {
        for kind in SourceKind.allCases {
            XCTAssertEqual(
                RemoteLibraryAccessPolicy.isRemoteLibrary(kind),
                kind != .local,
                "\(kind)"
            )
        }
    }

    func testAllTenProvidersAreReachableRemoteLibraryKinds() {
        let catalogKinds = Set(RemoteLibraryAccessPolicy.productSourceKinds)
        for kind in SourceKind.allCases where kind != .local {
            XCTAssertTrue(catalogKinds.contains(kind),
                          "\(kind) must resolve to a remote-library connector")
        }
    }

    func testEveryCatalogKindHasAnAppProviderPath() {
        for kind in RemoteLibraryAccessPolicy.productSourceKinds {
            XCTAssertTrue(RemoteLibraryProviderFactory.supports(kind), "\(kind)")
        }
    }
}
