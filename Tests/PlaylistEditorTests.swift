import GRDB
import Foundation
import Testing

@testable import TonearmCore

@Suite struct PlaylistEditorTests {
    @Test func testMoveToHeadRenumbersContiguously() {
        let edited = PlaylistEditor.move(items([10, 20, 30, 40]), from: 3, to: 0)

        #expect(edited.map(\.trackId) == [40, 10, 20, 30])
        XCTAssertContiguous(edited)
    }

    @Test func testMoveToTailRenumbersContiguously() {
        let edited = PlaylistEditor.move(items([10, 20, 30, 40]), from: 0, to: 3)

        #expect(edited.map(\.trackId) == [20, 30, 40, 10])
        XCTAssertContiguous(edited)
    }

    @Test func testMovePreservesDuplicateTrackIDsByItemIdentity() {
        let original = items([10, 10, 20, 10])
        let edited = PlaylistEditor.move(original, from: 1, to: 3)

        #expect(edited.map(\.id) == [1, 3, 4, 2])
        #expect(edited.map(\.trackId) == [10, 20, 10, 10])
        XCTAssertContiguous(edited)
    }

    @Test func testRemoveFromMiddleRenumbersContiguously() {
        let edited = PlaylistEditor.remove(items([10, 20, 30, 40]), at: 1)

        #expect(edited.map(\.trackId) == [10, 30, 40])
        XCTAssertContiguous(edited)
    }

    @Test func testEmptyPlaylistIsStable() {
        #expect(PlaylistEditor.normalized([]) == [])
        #expect(PlaylistEditor.move([], from: 0, to: 2) == [])
        #expect(PlaylistEditor.remove([], at: 0) == [])
    }

    @Test func testBPMSortIsAscendingStableAndPutsUnknownLast() {
        let original = items([10, 20, 30, 40])
        let edited = PlaylistEditor.sortedByBPM(
            original, bpmByTrackID: [10: 128, 20: 100, 40: 128])

        #expect(edited.map(\.trackId) == [20, 10, 40, 30])
        #expect(edited.map(\.position) == [0, 1, 2, 3])
    }

    @Test func testSwiftUIMoveOffsetsRenumbersContiguously() {
        let edited = PlaylistEditor.move(
            items([10, 20, 30, 40, 50]),
            fromOffsets: IndexSet([1, 2]),
            toOffset: 5)

        #expect(edited.map(\.trackId) == [10, 40, 50, 20, 30])
        XCTAssertContiguous(edited)
    }

    @Test func testSwiftUIDeleteOffsetsRenumbersContiguously() {
        let edited = PlaylistEditor.remove(
            items([10, 20, 30, 40, 50]),
            atOffsets: IndexSet([1, 3]))

        #expect(edited.map(\.trackId) == [10, 30, 50])
        XCTAssertContiguous(edited)
    }

    @Test func testNormalizesSparseAndDuplicatePositionsStably() {
        let original = [
            item(id: 3, position: 7, trackId: 30),
            item(id: 1, position: 4, trackId: 10),
            item(id: 2, position: 4, trackId: 20),
        ]

        let edited = PlaylistEditor.normalized(original)

        #expect(edited.map(\.id) == [1, 2, 3])
        XCTAssertContiguous(edited)
    }

    @Test func testLibraryStoreReorderAndRemovalRoundTripThroughGRDB() async throws {
        let store = try LibraryStore(inMemory: true)
        let trackIDs = try await seedTracks(into: store, count: 3)
        let playlist = try await store.createManualPlaylist(
            title: "Deduplicated",
            trackIds: [trackIDs[0], trackIDs[1], trackIDs[0], trackIDs[2]])
        let playlistID = try #require(playlist.id)
        let originalRows = try await store.playlistTrackRows(playlistId: playlistID)

        try await store.reorderPlaylist(id: playlistID, from: 2, to: 0)
        try await store.removeFromPlaylist(playlistId: playlistID, at: 1)

        let rows = try await store.playlistTrackRows(playlistId: playlistID)
        #expect(rows.map(\.row.id) == [trackIDs[2], trackIDs[1]])
        #expect(rows.map(\.item.id) == [originalRows[2].item.id, originalRows[1].item.id])
        #expect(rows.map(\.item.position) == [0, 1])
    }

    @Test func testLibraryStoreBPMSortPersistsAscendingOrderAndLeavesUnknownLast() async throws {
        let store = try LibraryStore(inMemory: true)
        let trackIDs = try await seedTracks(into: store, count: 3)
        for trackID in trackIDs {
            let asset = try await store.insertAsset(
                Asset(id: nil, trackId: trackID, kind: .remote, bookmark: nil, relPath: nil,
                      remoteURL: "https://example.com/\(trackID).mp3", altRemoteURL: nil,
                      sizeBytes: nil, unsupportedReason: nil))
            let analysis = DiscoveryTrackAnalysis(
                trackId: trackID, assetId: try #require(asset.id), assetRevision: 1,
                analysisVersion: 1, bpm: trackID == trackIDs[0] ? 128 : (trackID == trackIDs[1] ? 100 : nil),
                key: nil, energy: nil, phraseSummary: nil, analysisScopeSeconds: nil,
                completedAt: Date())
            try await store.dbQueue.write { db in
                var row = analysis
                try row.insert(db)
            }
        }
        let playlist = try await store.createManualPlaylist(
            title: "DJ Set", trackIds: [trackIDs[0], trackIDs[1], trackIDs[2]])

        try await store.sortPlaylistByBPM(id: try #require(playlist.id))
        let rows = try await store.playlistTrackRows(playlistId: try #require(playlist.id))
        #expect(rows.map(\.row.id) == [trackIDs[1], trackIDs[0], trackIDs[2]])
        #expect(rows.map(\.item.position) == [0, 1, 2])
    }

    private func items(_ trackIDs: [Int64]) -> [PlaylistItem] {
        trackIDs.enumerated().map { offset, trackID in
            item(id: Int64(offset + 1), position: offset, trackId: trackID)
        }
    }

    private func item(id: Int64, position: Int, trackId: Int64) -> PlaylistItem {
        PlaylistItem(
            id: id,
            playlistId: 99,
            position: position,
            trackId: trackId,
            sectionTitle: nil,
            syncID: "ITEM-\(id)")
    }

    private func seedTracks(into store: LibraryStore, count: Int) async throws -> [Int64] {
        let source = try await store.insertSource(
            Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                   title: "Fixture", addedAt: Date(), lastResolvedAt: nil,
                   followUpdates: false, licenseText: nil, memberCapHit: false))
        let sourceID = try #require(source.id)

        var ids: [Int64] = []
        for index in 0..<count {
            let track = try await store.insertTrack(
                Track(id: nil, albumId: nil, sourceId: sourceID, title: "Track \(index)",
                      trackNo: index + 1, discNo: nil, durationSec: nil, codec: nil,
                      sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "\(index)",
                      genre: nil, composer: nil, artistId: nil))
            ids.append(try #require(track.id))
        }
        return ids
    }

    private func XCTAssertContiguous(
        _ items: [PlaylistItem],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(items.map(\.position) == Array(items.indices), sourceLocation: sourceLocation)
    }
}
