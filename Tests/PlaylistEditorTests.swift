import GRDB
import XCTest

@testable import Tonearm

final class PlaylistEditorTests: XCTestCase {
    func testMoveToHeadRenumbersContiguously() {
        let edited = PlaylistEditor.move(items([10, 20, 30, 40]), from: 3, to: 0)

        XCTAssertEqual(edited.map(\.trackId), [40, 10, 20, 30])
        XCTAssertContiguous(edited)
    }

    func testMoveToTailRenumbersContiguously() {
        let edited = PlaylistEditor.move(items([10, 20, 30, 40]), from: 0, to: 3)

        XCTAssertEqual(edited.map(\.trackId), [20, 30, 40, 10])
        XCTAssertContiguous(edited)
    }

    func testMovePreservesDuplicateTrackIDsByItemIdentity() {
        let original = items([10, 10, 20, 10])
        let edited = PlaylistEditor.move(original, from: 1, to: 3)

        XCTAssertEqual(edited.map(\.id), [1, 3, 4, 2])
        XCTAssertEqual(edited.map(\.trackId), [10, 20, 10, 10])
        XCTAssertContiguous(edited)
    }

    func testRemoveFromMiddleRenumbersContiguously() {
        let edited = PlaylistEditor.remove(items([10, 20, 30, 40]), at: 1)

        XCTAssertEqual(edited.map(\.trackId), [10, 30, 40])
        XCTAssertContiguous(edited)
    }

    func testEmptyPlaylistIsStable() {
        XCTAssertEqual(PlaylistEditor.normalized([]), [])
        XCTAssertEqual(PlaylistEditor.move([], from: 0, to: 2), [])
        XCTAssertEqual(PlaylistEditor.remove([], at: 0), [])
    }

    func testSwiftUIMoveOffsetsRenumbersContiguously() {
        let edited = PlaylistEditor.move(
            items([10, 20, 30, 40, 50]),
            fromOffsets: IndexSet([1, 2]),
            toOffset: 5)

        XCTAssertEqual(edited.map(\.trackId), [10, 40, 50, 20, 30])
        XCTAssertContiguous(edited)
    }

    func testSwiftUIDeleteOffsetsRenumbersContiguously() {
        let edited = PlaylistEditor.remove(
            items([10, 20, 30, 40, 50]),
            atOffsets: IndexSet([1, 3]))

        XCTAssertEqual(edited.map(\.trackId), [10, 30, 50])
        XCTAssertContiguous(edited)
    }

    func testNormalizesSparseAndDuplicatePositionsStably() {
        let original = [
            item(id: 3, position: 7, trackId: 30),
            item(id: 1, position: 4, trackId: 10),
            item(id: 2, position: 4, trackId: 20),
        ]

        let edited = PlaylistEditor.normalized(original)

        XCTAssertEqual(edited.map(\.id), [1, 2, 3])
        XCTAssertContiguous(edited)
    }

    func testLibraryStoreReorderAndRemovalRoundTripThroughGRDB() async throws {
        let store = try LibraryStore(inMemory: true)
        let trackIDs = try await seedTracks(into: store, count: 3)
        let playlist = try await store.createManualPlaylist(
            title: "Duplicates",
            trackIds: [trackIDs[0], trackIDs[1], trackIDs[0], trackIDs[2]])
        let playlistID = try XCTUnwrap(playlist.id)
        let originalRows = try await store.playlistTrackRows(playlistId: playlistID)

        try await store.reorderPlaylist(id: playlistID, from: 2, to: 0)
        try await store.removeFromPlaylist(playlistId: playlistID, at: 1)

        let rows = try await store.playlistTrackRows(playlistId: playlistID)
        XCTAssertEqual(rows.map(\.row.id), [trackIDs[0], trackIDs[1], trackIDs[2]])
        XCTAssertEqual(rows.map(\.item.id), [originalRows[2].item.id, originalRows[1].item.id, originalRows[3].item.id])
        XCTAssertEqual(rows.map(\.item.position), [0, 1, 2])
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
        let sourceID = try XCTUnwrap(source.id)

        var ids: [Int64] = []
        for index in 0..<count {
            let track = try await store.insertTrack(
                Track(id: nil, albumId: nil, sourceId: sourceID, title: "Track \(index)",
                      trackNo: index + 1, discNo: nil, durationSec: nil, codec: nil,
                      sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "\(index)",
                      genre: nil, composer: nil, artistId: nil))
            ids.append(try XCTUnwrap(track.id))
        }
        return ids
    }

    private func XCTAssertContiguous(
        _ items: [PlaylistItem],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(items.map(\.position), Array(items.indices), file: file, line: line)
    }
}
