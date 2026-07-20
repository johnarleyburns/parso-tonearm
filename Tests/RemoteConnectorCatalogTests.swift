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
            .iaList,
        ])
    }

    func testArchiveConnectorsAreLastInAddRemoteLibraryPickerOrder() {
        XCTAssertEqual(Array(RemoteConnectorCatalog.all.map(\.id).suffix(2)), [
            "iaPublicList",
            "iaPrivateList",
        ])
    }

    func testTierSplitMatchesSupportPlan() {
        let guided = Set(RemoteConnectorCatalog.all.filter { $0.tier == .guided }.map(\.sourceKind))
        let advanced = Set(RemoteConnectorCatalog.all.filter { $0.tier == .advanced }.map(\.sourceKind))

        XCTAssertEqual(guided, Set([.dropbox, .googleDrive, .oneDrive, .pCloud, .subsonic, .webDAV, .jellyfin, .iaList]))
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

    func testPaywallRemoteLibraryCopyListsEveryConnector() throws {
        let model = ProPaywallModel()
        let detail = try XCTUnwrap(model.features.first { $0.title == "Remote Libraries" }?.detail)

        for connector in RemoteConnectorCatalog.all {
            XCTAssertTrue(detail.contains(connector.proDisplayName), "\(connector.proDisplayName) missing from Pro copy")
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
