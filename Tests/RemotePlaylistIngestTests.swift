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
}
