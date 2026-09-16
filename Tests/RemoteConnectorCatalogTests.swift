import XCTest

@testable import TonearmCore

@MainActor
final class RemoteConnectorCatalogTests: XCTestCase {
    func testCatalogListsExactlyTheSupportedRemoteConnectors() {
        XCTAssertEqual(RemoteConnectorCatalog.productSourceKinds, [
            .subsonic,
            .webDAV,
            .smb,
            .jellyfin,
            .plex,
            .dropbox,
            .googleDrive,
            .oneDrive,
            .pCloud,
            .iaItem,
            .iaList,
            .iaCollection,
            .iaFavorites,
        ])
    }

    func testArchiveConnectorsAreLastInAddRemoteLibraryPickerOrder() {
        XCTAssertEqual(Array(RemoteConnectorCatalog.all.map(\.id).suffix(2)), [
            "iaPublicList",
            "iaPrivateList",
        ])
    }

    func testEveryRemoteSourceKindResolvesToAConnector() {
        // `.jamendoGenre` deliberately has no connector: the "Jamendo
        // genres" onboarding/Add-Library entry was removed (Jamendo's real
        // API has no personal/private-collection concept to build an
        // "add your own login" path on top of, and a dedicated genre-browse
        // connector for one public CC catalog wasn't judged worth the
        // onboarding real estate). The underlying provider/source kind is
        // left in place, unreachable, for any library that already has one.
        for kind in SourceKind.allCases where kind != .local && kind != .jamendoGenre {
            XCTAssertFalse(
                RemoteConnectorCatalog.connectors(for: kind).isEmpty,
                "Missing connector for \(kind.rawValue)"
            )
        }
    }

    func testPublicArchiveConnectorServesEveryArchiveSourceKind() {
        XCTAssertEqual(
            RemoteConnectorCatalog.connector(byID: "iaPublicList")?.sourceKinds,
            [.iaItem, .iaList, .iaCollection, .iaFavorites]
        )
    }

    func testTierSplitMatchesSupportPlan() {
        let guided = Set(RemoteConnectorCatalog.all.filter { $0.tier == .guided }.flatMap(\.sourceKinds))
        let advanced = Set(RemoteConnectorCatalog.all.filter { $0.tier == .advanced }.flatMap(\.sourceKinds))

        XCTAssertEqual(guided, Set([.dropbox, .googleDrive, .oneDrive, .pCloud, .subsonic, .webDAV, .jellyfin, .iaItem, .iaList, .iaCollection, .iaFavorites]))
        XCTAssertEqual(advanced, Set([.plex, .smb]))
    }

    func testEveryConnectorHasGuideContent() {
        for connector in RemoteConnectorCatalog.all {
            XCTAssertFalse(connector.guide.title.isEmpty, "\(connector.title) guide needs a title")
            XCTAssertEqual(connector.guide.sections.map(\.title), [
                "Prerequisites",
                "Setup",
                "Troubleshooting",
                "Privacy",
            ])
            XCTAssertTrue(connector.guide.sections.allSatisfy { !$0.body.isEmpty })
        }
    }

    func testReadmeRemoteConnectorSectionListsEveryConnector() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let readmeURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let readme = try String(contentsOf: readmeURL, encoding: .utf8)

        for connector in RemoteConnectorCatalog.all {
            XCTAssertTrue(readme.contains(connector.proDisplayName), "\(connector.proDisplayName) missing from README")
        }
    }
}
