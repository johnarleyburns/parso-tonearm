import GRDB
import XCTest

@testable import Tonearm

final class RemoteLibraryProviderTests: XCTestCase {

    func testFakeProviderConformanceRoutesBrowseResolveAndRefresh() async throws {
        let audioURL = try XCTUnwrap(URL(string: "https://example.com/audio/track.flac"))
        let node = RemoteNode(
            id: "track-1",
            title: "Track 1",
            path: "Albums/Track 1.flac",
            kind: .audio,
            sizeBytes: 128
        )
        let provider = FakeRemoteProvider(
            sourceKind: .subsonic,
            nodesByPath: ["Albums": [node]],
            assetsByNodeID: [
                "track-1": ResolvedAsset(
                    url: audioURL,
                    headers: ["Authorization": "Bearer token"],
                    supportsByteRanges: true,
                    sizeBytes: 128
                )
            ]
        )

        let browsed = try await provider.browse(path: "Albums")
        let resolved = try await provider.resolve(node: try XCTUnwrap(browsed.first))
        try await provider.refresh()

        XCTAssertEqual(provider.sourceKind, .subsonic)
        XCTAssertEqual(browsed, [node])
        XCTAssertEqual(resolved.url, audioURL)
        XCTAssertEqual(resolved.headers["Authorization"], "Bearer token")
        XCTAssertEqual(provider.refreshCount, 1)
    }

    func testIAResolverIsARemoteLibraryProvider() {
        let provider: any RemoteLibraryProvider = IARemoteLibraryProvider(preferFLAC: false)

        XCTAssertEqual(provider.sourceKind, .iaItem)
    }

    func testSourceKindIncludesPhaseERemoteProviders() {
        XCTAssertTrue(SourceKind.allCases.contains(.subsonic))
        XCTAssertTrue(SourceKind.allCases.contains(.webDAV))
        XCTAssertTrue(SourceKind.allCases.contains(.smb))
        XCTAssertTrue(SourceKind.allCases.contains(.jellyfin))
        XCTAssertTrue(SourceKind.allCases.contains(.plex))
        XCTAssertTrue(SourceKind.allCases.contains(.dropbox))
        XCTAssertTrue(SourceKind.allCases.contains(.googleDrive))
        XCTAssertTrue(SourceKind.allCases.contains(.oneDrive))
        XCTAssertTrue(SourceKind.allCases.contains(.pCloud))
    }

    func testProviderFactoryDeclaresEveryProductRemoteKindSupported() {
        for kind in RemoteLibraryAccessPolicy.productSourceKinds {
            XCTAssertTrue(RemoteLibraryProviderFactory.supports(kind), "\(kind) should have a product provider path")
        }
    }

    func testV11MigrationAcceptsRemoteProviderSourceKind() throws {
        let dbQueue = try DatabaseQueue()
        try Schema.migrator(upTo: "v11").migrate(dbQueue)

        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source
                        (kind, title, addedAt, followUpdates, memberCapHit, localIsFolder)
                    VALUES (?, 'Remote', ?, 0, 0, 0)
                    """,
                arguments: [SourceKind.subsonic.rawValue, Date(timeIntervalSince1970: 1)]
            )
            let kind = try String.fetchOne(db, sql: "SELECT kind FROM source")
            XCTAssertEqual(kind, SourceKind.subsonic.rawValue)
        }
    }

    private final class FakeRemoteProvider: RemoteLibraryProvider {
        let sourceKind: SourceKind
        private let nodesByPath: [String: [RemoteNode]]
        private let assetsByNodeID: [String: ResolvedAsset]
        private(set) var refreshCount = 0

        init(sourceKind: SourceKind,
             nodesByPath: [String: [RemoteNode]],
             assetsByNodeID: [String: ResolvedAsset]) {
            self.sourceKind = sourceKind
            self.nodesByPath = nodesByPath
            self.assetsByNodeID = assetsByNodeID
        }

        func browse(path: String) async throws -> [RemoteNode] {
            nodesByPath[path] ?? []
        }

        func resolve(node: RemoteNode) async throws -> ResolvedAsset {
            guard let asset = assetsByNodeID[node.id] else {
                throw URLError(.badURL)
            }
            return asset
        }

        func refresh() async throws {
            refreshCount += 1
        }
    }
}
