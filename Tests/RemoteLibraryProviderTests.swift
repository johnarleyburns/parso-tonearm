import GRDB
import Foundation
import Testing

@testable import TonearmCore

@Suite struct RemoteLibraryProviderTests {

    @Test func testFakeProviderConformanceRoutesBrowseResolveAndRefresh() async throws {
        let audioURL = try #require(URL(string: "https://example.com/audio/track.flac"))
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
        let resolved = try await provider.resolve(node: try #require(browsed.first))
        try await provider.refresh()

        #expect(provider.sourceKind == .subsonic)
        #expect(browsed == [node])
        #expect(resolved.url == audioURL)
        #expect(resolved.headers["Authorization"] == "Bearer token")
        #expect(provider.refreshCount == 1)
    }

    @Test func testIAResolverIsARemoteLibraryProvider() {
        let provider: any RemoteLibraryProvider = IARemoteLibraryProvider(preferFLAC: false)

        #expect(provider.sourceKind == .iaItem)
    }

    @Test func testSourceKindIncludesPhaseERemoteProviders() {
        #expect(SourceKind.allCases.contains(.subsonic))
        #expect(SourceKind.allCases.contains(.webDAV))
        #expect(SourceKind.allCases.contains(.smb))
        #expect(SourceKind.allCases.contains(.jellyfin))
        #expect(SourceKind.allCases.contains(.plex))
        #expect(SourceKind.allCases.contains(.dropbox))
        #expect(SourceKind.allCases.contains(.googleDrive))
        #expect(SourceKind.allCases.contains(.oneDrive))
        #expect(SourceKind.allCases.contains(.pCloud))
        #expect(SourceKind.allCases.contains(.box))
        #expect(SourceKind.allCases.contains(.yandexDisk))
        #expect(SourceKind.allCases.contains(.emby))
    }

    @Test func testProviderFactoryDeclaresEveryProductRemoteKindSupported() {
        for kind in RemoteLibraryAccessPolicy.productSourceKinds {
            #expect(RemoteLibraryProviderFactory.supports(kind), "\(kind) should have a product provider path")
        }
    }

    /// Real bug: `RemoteLibraryProviderFactory.provider(for:)` fell through
    /// to `.unsupportedURL` for every Internet Archive source kind, despite
    /// `supports` already reporting them as remote libraries — breaking
    /// both `RemoteSparseAssetResolver`'s analysis-time re-authentication
    /// and the remote-indexing backfill for what is very likely this app's
    /// single largest remote-library source type.
    @Test func testProviderFactoryConstructsAnIAProviderForEveryArchiveKind() throws {
        for kind in [SourceKind.iaItem, .iaList, .iaCollection, .iaFavorites] {
            let source = Source(
                id: 1, kind: kind, iaIdentifier: "some-item", originalURL: "https://archive.org/details/some-item",
                title: "Test", addedAt: Date(), lastResolvedAt: Date(), followUpdates: false,
                licenseText: nil, memberCapHit: false)
            let provider = try RemoteLibraryProviderFactory.provider(for: source)
            #expect(provider is IARemoteLibraryProvider, "\(kind) should construct an IARemoteLibraryProvider")
        }
    }

    /// Real bug found in the same audit: a private IA list's saved
    /// password (`AppState.addIASource`, account "ia-private:<sourceID>")
    /// was never returned here, so `AppState.deleteSource` never cleaned
    /// it up on delete — the credential stayed in the Keychain forever.
    @Test func testCredentialAccountsIncludesIAPrivateListAccount() {
        for kind in [SourceKind.iaItem, .iaList, .iaCollection, .iaFavorites] {
            let accounts = RemoteLibraryProviderFactory.credentialAccounts(for: 42, kind: kind)
            #expect(accounts == ["ia-private:42"], "\(kind) should report its private-list credential account")
        }
    }

    @Test func testV11MigrationAcceptsRemoteProviderSourceKind() throws {
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
            #expect(kind == SourceKind.subsonic.rawValue)
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
