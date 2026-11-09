import XCTest
@testable import TonearmCore

final class RemotePlaylistIngestTests: XCTestCase {
    func testPersistsInOrderDeduplicatesAndKeepsCredentialsTransient() async throws {
        let store = try LibraryStore(inMemory: true)
        let source = try await store.insertSource(Source(
            id: nil, kind: .webDAV, iaIdentifier: nil, originalURL: nil, title: "Server",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let nodes = (1...3).map {
            RemoteNode(id: "\($0)", title: "Track \($0)", path: "/\($0).mp3", kind: .audio)
        }
        let resolve: @Sendable (RemoteNode) async throws -> ResolvedAsset = { node in
            ResolvedAsset(url: URL(string: "https://example.test\(node.path)")!,
                          headers: ["Authorization": "secret"], sizeBytes: 10)
        }
        let first = await RemotePlaylistIngest.persist(nodes: nodes, resolve: resolve,
                                                       source: source, store: store)
        XCTAssertEqual(first.trackIDs.count, 3)
        XCTAssertEqual(first.skipped, 0)
        let second = await RemotePlaylistIngest.persist(nodes: nodes, resolve: resolve,
                                                        source: source, store: store)
        XCTAssertEqual(second.trackIDs, first.trackIDs)
        let rows = try await store.tracks(forSource: source.id!)
        XCTAssertEqual(rows.count, 3)
        XCTAssertTrue(rows.allSatisfy { $0.asset?.transientRemoteHeaders.isEmpty == true })
        // Real bug fix: the provider-native node id/path MUST survive a save
        // (unlike the transient credentials above) — without it, nothing can
        // ever re-authenticate this asset again in the background. See
        // `Asset.remoteNodeID`'s doc / docs/plans/remote-sparse-indexing.md.
        for (index, row) in rows.enumerated() {
            XCTAssertEqual(row.asset?.remoteNodeID, "\(index + 1)")
            XCTAssertEqual(row.asset?.remoteNodePath, "/\(index + 1).mp3")
        }
    }

    /// Real report: a Google Drive/Dropbox track played fine once (straight from browsing, where
    /// `RemoteTrackRowFactory` sets `Asset.remoteContentType` on the in-memory row), then never
    /// played again once persisted to the library and replayed from its now-complete cache —
    /// `RemotePlaylistIngest.persist`'s own `Asset(...)` never carried `node.contentType` through
    /// at all, so every DB-backed row lost the one format hint AVFoundation has for an
    /// extensionless cloud-drive stream URL.
    func testPersistCarriesTheProvidersContentTypeOntoTheSavedAsset() async throws {
        let store = try LibraryStore(inMemory: true)
        let source = try await store.insertSource(Source(
            id: nil, kind: .googleDrive, iaIdentifier: nil, originalURL: nil, title: "Drive",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        var node = RemoteNode(id: "file-1", title: "Song", path: "/file-1", kind: .audio)
        node.contentType = "audio/mp4"

        let result = await RemotePlaylistIngest.persist(nodes: [node], resolve: { _ in
            ResolvedAsset(url: URL(string: "https://example.test/alt=media")!)
        }, source: source, store: store)
        XCTAssertEqual(result.trackIDs.count, 1)

        let rows = try await store.tracks(forSource: source.id!)
        XCTAssertEqual(rows.first?.asset?.remoteContentType, "audio/mp4")
    }

    /// Real report: re-browsing to and replaying the same Dropbox/Google Drive file created a
    /// genuine duplicate track, rather than finding the one already imported, and the duplicate
    /// then got favorited separately too ("it shows as not favorited" the second time, "clicking
    /// favorites again creates another duplicate entry"). Simulates the second `persist` call
    /// getting back a DIFFERENT resolved URL for the exact same provider node — the stable
    /// identity (`node.id`) must still be recognized as the same track, not a new one.
    func testSameNodeIDWithADifferentResolvedURLIsNotDuplicated() async throws {
        let store = try LibraryStore(inMemory: true)
        let source = try await store.insertSource(Source(
            id: nil, kind: .dropbox, iaIdentifier: nil, originalURL: nil, title: "Dropbox",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let node = RemoteNode(id: "stable-drive-id-42", title: "Song", path: "/song.mp3", kind: .audio)

        let first = await RemotePlaylistIngest.persist(nodes: [node], resolve: { _ in
            ResolvedAsset(url: URL(string: "https://example.test/first-temp-link")!)
        }, source: source, store: store)
        XCTAssertEqual(first.trackIDs.count, 1)

        // Same node, a completely different resolved URL (e.g. a fresh, differently-signed temp
        // link) -- must still resolve to the SAME track, not a second one.
        let second = await RemotePlaylistIngest.persist(nodes: [node], resolve: { _ in
            ResolvedAsset(url: URL(string: "https://example.test/second-temp-link")!)
        }, source: source, store: store)
        XCTAssertEqual(second.trackIDs, first.trackIDs, "the same provider node must never be duplicated")

        let rows = try await store.tracks(forSource: source.id!)
        XCTAssertEqual(rows.count, 1, "must still be exactly one track, not two")
        XCTAssertEqual(rows.first?.asset?.remoteURL, "https://example.test/second-temp-link",
                       "the stored locator should refresh to the latest resolve, not stay stuck on the first")
    }

    func testResolveFailureSkipsOnlyThatNode() async throws {
        enum Failure: Error { case expected }
        let store = try LibraryStore(inMemory: true)
        let source = try await store.insertSource(Source(
            id: nil, kind: .webDAV, iaIdentifier: nil, originalURL: nil, title: "Server",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let nodes = [RemoteNode(id: "ok", title: "OK", path: "/ok", kind: .audio),
                     RemoteNode(id: "bad", title: "Bad", path: "/bad", kind: .audio)]
        let result = await RemotePlaylistIngest.persist(nodes: nodes, resolve: { node in
            if node.id == "bad" { throw Failure.expected }
            return ResolvedAsset(url: URL(string: "https://example.test/ok")!)
        }, source: source, store: store)
        XCTAssertEqual(result.trackIDs.count, 1)
        XCTAssertEqual(result.skipped, 1)
    }

    // MARK: - Jamendo durable catalog identity

    private func source(_ kind: SourceKind, in store: LibraryStore) async throws -> Source {
        try await store.insertSource(Source(
            id: nil, kind: kind, iaIdentifier: nil, originalURL: nil, title: "Src",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
    }

    private func jamendoSource(in store: LibraryStore) async throws -> Source {
        try await source(.jamendoGenre, in: store)
    }

    func testJamendoIngestCreatesDurableCatalogLocatorFromProviderNodeID() async throws {
        let store = try LibraryStore(inMemory: true)
        let source = try await jamendoSource(in: store)
        let node = RemoteNode(id: "99123", title: "Song", path: "track/99123", kind: .audio)
        let stream = URL(string: "https://stream.example.test/?trackid=99123&format=mp32")!
        _ = await RemotePlaylistIngest.persist(nodes: [node], resolve: { _ in ResolvedAsset(url: stream) },
                                               source: source, store: store)
        let row = try await store.blendCatalogTrack(key: BlendCatalogTrack.jamendoKey(trackID: "99123"))
        XCTAssertEqual(row?.sourceKind, .jamendo)
        XCTAssertEqual(row?.providerTrackID, "99123")
        XCTAssertEqual(row?.cachedURL, stream.absoluteString)
        XCTAssertEqual(row?.state, .unindexed)
        XCTAssertEqual(row?.audioLocator(), .jamendo(trackID: "99123", cachedURL: stream, expiry: nil))
    }

    func testInvalidJamendoNodeIDsAreSkippedButNonJamendoIsNotValidated() async throws {
        let store = try LibraryStore(inMemory: true)
        let jamendo = try await jamendoSource(in: store)
        let url = URL(string: "https://stream.example.test/x")!
        let bad = ["", "  ", "abc", "12x"].map { RemoteNode(id: $0, title: "T", path: "p/\($0)", kind: .audio) }
        let result = await RemotePlaylistIngest.persist(nodes: bad, resolve: { _ in ResolvedAsset(url: url) },
                                                        source: jamendo, store: store)
        XCTAssertEqual(result.skipped, bad.count)
        XCTAssertTrue(result.trackIDs.isEmpty)

        let other = try await source(.iaItem, in: store)
        let node = RemoteNode(id: "abc", title: "T", path: "/abc.mp3", kind: .audio)
        let ok = await RemotePlaylistIngest.persist(nodes: [node], resolve: { _ in ResolvedAsset(url: url) },
                                                    source: other, store: store)
        XCTAssertEqual(ok.skipped, 0)
        XCTAssertEqual(ok.trackIDs.count, 1)
    }

    func testNonJamendoRemoteIngestDoesNotCreateJamendoCatalogRow() async throws {
        let store = try LibraryStore(inMemory: true)
        let source = try await source(.iaItem, in: store)
        let node = RemoteNode(id: "99123", title: "Song", path: "/99123.mp3", kind: .audio)
        _ = await RemotePlaylistIngest.persist(nodes: [node], resolve: { _ in
            ResolvedAsset(url: URL(string: "https://example.test/99123.mp3")!)
        }, source: source, store: store)
        let row = try await store.blendCatalogTrack(key: BlendCatalogTrack.jamendoKey(trackID: "99123"))
        XCTAssertNil(row)
    }

    func testJamendoCatalogCompanionFailureDoesNotReportTheNodeAsPersisted() async throws {
        struct Boom: Error {}
        let store = try LibraryStore(inMemory: true)
        let source = try await jamendoSource(in: store)
        let node = RemoteNode(id: "99123", title: "Song", path: "track/99123", kind: .audio)
        let result = await RemotePlaylistIngest.persist(
            nodes: [node], resolve: { _ in ResolvedAsset(url: URL(string: "https://stream.example.test/?trackid=99123")!) },
            source: source, store: store, catalogUpsert: { _, _, _ in throw Boom() })
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(result.trackIDs.isEmpty)
        let tracks = try await store.tracks(forSource: source.id!)
        XCTAssertTrue(tracks.isEmpty)
        let row = try await store.blendCatalogTrack(key: BlendCatalogTrack.jamendoKey(trackID: "99123"))
        XCTAssertNil(row)
    }

    func testJamendoReimportWithRefreshedURLKeepsOneTrackAndRefreshesOnlyCacheData() async throws {
        let store = try LibraryStore(inMemory: true)
        let source = try await jamendoSource(in: store)
        let node = RemoteNode(id: "99123", title: "Song", path: "track/99123", kind: .audio)
        let old = URL(string: "https://old.example/?trackid=99123")!
        let fresh = URL(string: "https://new.example/?trackid=99123")!
        let first = await RemotePlaylistIngest.persist(nodes: [node], resolve: { _ in ResolvedAsset(url: old) },
                                                       source: source, store: store)
        let trackID = try XCTUnwrap(first.trackIDs.first)
        let key = BlendCatalogTrack.jamendoKey(trackID: node.id)
        let second = await RemotePlaylistIngest.persist(nodes: [node], resolve: { _ in ResolvedAsset(url: fresh) },
                                                        source: source, store: store)
        XCTAssertEqual(second.trackIDs, [trackID])
        XCTAssertEqual(second.skipped, 0)
        let rows = try await store.tracks(forSource: try XCTUnwrap(source.id))
        XCTAssertEqual(rows.count, 1)
        let freshRow = try await store.trackRow(id: trackID)
        XCTAssertEqual(freshRow?.asset?.remoteURL, fresh.absoluteString)
        let catalogRow = try await store.blendCatalogTrack(key: key)
        let catalog = try XCTUnwrap(catalogRow)
        XCTAssertEqual(catalog.cachedURL, fresh.absoluteString)
    }

    func testSameURLDifferentJamendoNodeIDsRemainDistinctTracks() async throws {
        let store = try LibraryStore(inMemory: true)
        let source = try await jamendoSource(in: store)
        let a = RemoteNode(id: "1", title: "A", path: "track/1", kind: .audio)
        let b = RemoteNode(id: "2", title: "B", path: "track/2", kind: .audio)
        let url = URL(string: "https://same.example/stream")!
        let result = await RemotePlaylistIngest.persist(nodes: [a, b], resolve: { _ in ResolvedAsset(url: url) },
                                                        source: source, store: store)
        XCTAssertEqual(result.trackIDs.count, 2)
        let rows = try await store.tracks(forSource: try XCTUnwrap(source.id))
        XCTAssertEqual(rows.count, 2)
    }

    func testCatalogRefreshFailureDoesNotPartiallyRefreshAssetOrReportImportSuccess() async throws {
        struct Boom: Error {}
        let store = try LibraryStore(inMemory: true)
        let source = try await jamendoSource(in: store)
        let node = RemoteNode(id: "99123", title: "Song", path: "track/99123", kind: .audio)
        let old = URL(string: "https://old.example/?trackid=99123")!
        let first = await RemotePlaylistIngest.persist(nodes: [node], resolve: { _ in ResolvedAsset(url: old) },
                                                       source: source, store: store)
        let trackID = try XCTUnwrap(first.trackIDs.first)
        let second = await RemotePlaylistIngest.persist(
            nodes: [node], resolve: { _ in ResolvedAsset(url: URL(string: "https://new.example/?trackid=99123")!) },
            source: source, store: store, catalogUpsert: { _, _, _ in throw Boom() })
        XCTAssertEqual(second.skipped, 1)
        XCTAssertTrue(second.trackIDs.isEmpty)
        let oldRow = try await store.trackRow(id: trackID)
        XCTAssertEqual(oldRow?.asset?.remoteURL, old.absoluteString)
        let rows = try await store.tracks(forSource: try XCTUnwrap(source.id))
        XCTAssertEqual(rows.count, 1)
    }
}
