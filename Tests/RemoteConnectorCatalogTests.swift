import Testing

@testable import TonearmCore

@MainActor
@Suite struct RemoteConnectorCatalogTests {
    @Test func testCatalogListsExactlyTheSupportedRemoteConnectors() {
        #expect(RemoteConnectorCatalog.productSourceKinds == [
            .subsonic,
            .webDAV,
            .smb,
            .jellyfin,
            .emby,
            .plex,
            .dropbox,
            .googleDrive,
            .oneDrive,
            .pCloud,
            .box,
            .yandexDisk,
            .iaItem,
            .iaList,
            .iaCollection,
            .iaFavorites,
        ])
    }

    @Test func testArchiveConnectorsAreLastInAddRemoteLibraryPickerOrder() {
        #expect(Array(RemoteConnectorCatalog.all.map(\.id).suffix(2)) == [
            "iaPublicList",
            "iaPrivateList",
        ])
    }

    @Test func testEveryRemoteSourceKindResolvesToAConnector() {
        // `.jamendoGenre` deliberately has no connector: the "Jamendo
        // genres" onboarding/Add-Library entry was removed (Jamendo's real
        // API has no personal/private-collection concept to build an
        // "add your own login" path on top of, and a dedicated genre-browse
        // connector for one public CC catalog wasn't judged worth the
        // onboarding real estate). The underlying provider/source kind is
        // left in place, unreachable, for any library that already has one.
        for kind in SourceKind.allCases where kind != .local && kind != .jamendoGenre {
            #expect(
                !RemoteConnectorCatalog.connectors(for: kind).isEmpty,
                "Missing connector for \(kind.rawValue)"
            )
        }
    }

    @Test func testPublicArchiveConnectorServesEveryArchiveSourceKind() {
        #expect(
            RemoteConnectorCatalog.connector(byID: "iaPublicList")?.sourceKinds ==
            [.iaItem, .iaList, .iaCollection, .iaFavorites]
        )
    }

    @Test func testTierSplitMatchesSupportPlan() {
        let guided = Set(RemoteConnectorCatalog.all.filter { $0.tier == .guided }.flatMap(\.sourceKinds))
        let advanced = Set(RemoteConnectorCatalog.all.filter { $0.tier == .advanced }.flatMap(\.sourceKinds))

        #expect(guided == Set([.dropbox, .googleDrive, .oneDrive, .pCloud, .box, .yandexDisk, .subsonic, .webDAV, .jellyfin, .emby, .iaItem, .iaList, .iaCollection, .iaFavorites]))
        #expect(advanced == Set([.plex, .smb]))
    }

    @Test func testEveryConnectorHasGuideContent() {
        for connector in RemoteConnectorCatalog.all {
            #expect(!connector.guide.title.isEmpty, "\(connector.title) guide needs a title")
            #expect(connector.guide.sections.map(\.title) == [
                "Prerequisites",
                "Setup",
                "Troubleshooting",
                "Privacy",
            ])
            #expect(connector.guide.sections.allSatisfy { !$0.body.isEmpty })
        }
    }

    @Test func testReadmeRemoteConnectorSectionListsEveryConnector() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let readmeURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let readme = try String(contentsOf: readmeURL, encoding: .utf8)

        for connector in RemoteConnectorCatalog.all {
            #expect(readme.contains(connector.proDisplayName), "\(connector.proDisplayName) missing from README")
        }
    }
}
