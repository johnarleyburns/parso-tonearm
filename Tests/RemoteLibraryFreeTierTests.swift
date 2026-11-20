import Testing
@testable import TonearmCore

/// Commit 0.4 removes the last purchase gate — `ProFeature.remoteLibraries`
/// (FR-LIB-7). Remote libraries are free for everyone, and
/// `RemoteLibraryAccessPolicy` no longer makes a purchase decision at all; it
/// only classifies. These tests pin that classification so every one of the ten
/// providers keeps a real code path and the free flip cannot silently drop one.
@Suite struct RemoteLibraryFreeTierTests {

    @Test func testEveryNonLocalSourceKindIsClassifiedAsRemoteLibrary() {
        // `.jamendoGenre` deliberately opted out of the catalog (see
        // RemoteConnectorCatalogTests.testEveryRemoteSourceKindResolvesToAConnector
        // for why) — it's no longer a reachable remote-library connector.
        for kind in SourceKind.allCases where kind != .jamendoGenre {
            #expect(
                RemoteLibraryAccessPolicy.isRemoteLibrary(kind) ==
                (kind != .local),
                "\(kind)"
            )
        }
    }

    @Test func testAllTenProvidersAreReachableRemoteLibraryKinds() {
        let catalogKinds = Set(RemoteLibraryAccessPolicy.productSourceKinds)
        for kind in SourceKind.allCases where kind != .local && kind != .jamendoGenre {
            #expect(catalogKinds.contains(kind),
                          "\(kind) must resolve to a remote-library connector")
        }
    }

    @Test func testEveryCatalogKindHasAnAppProviderPath() {
        for kind in RemoteLibraryAccessPolicy.productSourceKinds {
            #expect(RemoteLibraryProviderFactory.supports(kind), "\(kind)")
        }
    }
}
