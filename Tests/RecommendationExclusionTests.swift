import XCTest
import GRDB
@testable import TonearmCore

final class RecommendationExclusionTests: XCTestCase {

    private func seed(_ store: LibraryStore, nodeID: String) async throws -> Int64 {
        let source = try await store.insertSource(
            Source(id: nil, kind: .jamendoGenre, iaIdentifier: nil, originalURL: nil,
                   title: "Src", addedAt: Date(), lastResolvedAt: nil,
                   followUpdates: false, licenseText: nil, memberCapHit: false,
                   localIsFolder: false, artworkTrackId: nil))
        let track = try await store.insertTrack(
            Track(id: nil, albumId: nil, sourceId: try XCTUnwrap(source.id), title: "T",
                  trackNo: 1, discNo: nil, durationSec: nil, codec: nil,
                  sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "a"))
        let trackId = try XCTUnwrap(track.id)
        _ = try await store.insertAsset(
            Asset(id: nil, trackId: trackId, kind: .remote, bookmark: nil, relPath: nil,
                  remoteURL: "https://x/\(nodeID)", altRemoteURL: nil, sizeBytes: nil,
                  unsupportedReason: nil, remoteNodeID: nodeID))
        return trackId
    }

    func testExcludeAndLookup() async throws {
        let store = try LibraryStore(inMemory: true)
        try await store.excludeFromRecommendations(sourceKind: .jamendoGenre, remoteNodeID: "abc",
                                                   reason: "neverRecommend")
        let hit = try await store.isExcludedFromRecommendations(sourceKind: .jamendoGenre, remoteNodeID: "abc")
        let otherNode = try await store.isExcludedFromRecommendations(sourceKind: .jamendoGenre, remoteNodeID: "z")
        let otherKind = try await store.isExcludedFromRecommendations(sourceKind: .plex, remoteNodeID: "abc")
        XCTAssertTrue(hit)
        XCTAssertFalse(otherNode)
        XCTAssertFalse(otherKind)
        let ids = try await store.excludedRemoteNodeIDs(sourceKind: .jamendoGenre)
        XCTAssertEqual(ids, ["abc"])
    }

    func testDeleteWritesSurvivingExclusionAndReAddStaysExcluded() async throws {
        let store = try LibraryStore(inMemory: true)
        let oldId = try await seed(store, nodeID: "n1")
        try await store.deleteTrack(id: oldId)
        let excluded = try await store.isExcludedFromRecommendations(sourceKind: .jamendoGenre, remoteNodeID: "n1")
        XCTAssertTrue(excluded)
        let reason = try await store.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT reason FROM recommendation_exclusion WHERE remoteNodeID = 'n1'")
        }
        XCTAssertEqual(reason, "removedFromLibrary")

        let newId = try await seed(store, nodeID: "n1")
        XCTAssertNotEqual(newId, oldId)
        let ids = try await store.excludedTrackIDs()
        XCTAssertEqual(ids, [newId])
    }

    func testViewWiringIsPinned() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let comps = try String(contentsOf: root.appendingPathComponent("Sources/Features/Components.swift"))
        XCTAssertTrue(comps.contains("if showNeverRecommend"))
        XCTAssertTrue(comps.contains("excludeFromRecommendations(row)"))
        let listen = try String(contentsOf: root.appendingPathComponent("Sources/Features/Listen/ListenView.swift"))
        XCTAssertTrue(listen.contains("identifier: \"listen.favorites\",\n                showNeverRecommend: true)"))
    }
}
