import GRDB
import XCTest

@testable import TonearmCore

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

    /// Real bug: `RemoteLibraryProviderFactory.provider(for:)` fell through
    /// to `.unsupportedURL` for every Internet Archive source kind, despite
    /// `supports` already reporting them as remote libraries — breaking
    /// both `RemoteSparseAssetResolver`'s analysis-time re-authentication
    /// and the remote-indexing backfill for what is very likely this app's
    /// single largest remote-library source type.
    func testProviderFactoryConstructsAnIAProviderForEveryArchiveKind() throws {
        for kind in [SourceKind.iaItem, .iaList, .iaCollection, .iaFavorites] {
            let source = Source(
                id: 1, kind: kind, iaIdentifier: "some-item", originalURL: "https://archive.org/details/some-item",
                title: "Test", addedAt: Date(), lastResolvedAt: Date(), followUpdates: false,
                licenseText: nil, memberCapHit: false)
            let provider = try RemoteLibraryProviderFactory.provider(for: source)
            XCTAssertTrue(provider is IARemoteLibraryProvider, "\(kind) should construct an IARemoteLibraryProvider")
        }
    }

    /// Real bug found in the same audit: a private IA list's saved
    /// password (`AppState.addIASource`, account "ia-private:<sourceID>")
    /// was never returned here, so `AppState.deleteSource` never cleaned
    /// it up on delete — the credential stayed in the Keychain forever.
    func testCredentialAccountsIncludesIAPrivateListAccount() {
        for kind in [SourceKind.iaItem, .iaList, .iaCollection, .iaFavorites] {
            let accounts = RemoteLibraryProviderFactory.credentialAccounts(for: 42, kind: kind)
            XCTAssertEqual(accounts, ["ia-private:42"], "\(kind) should report its private-list credential account")
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

    private final class FakeRemoteProvider: @unchecked Sendable, RemoteLibraryProvider {
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
