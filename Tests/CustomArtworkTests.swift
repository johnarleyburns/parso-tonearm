import XCTest
import GRDB
@testable import TonearmCore

final class CustomArtworkTests: XCTestCase {

    private func makeStore() throws -> LibraryStore {
        try LibraryStore(inMemory: true)
    }

    private func seedTrack(_ store: LibraryStore, sourceTitle: String = "Src") async throws -> (sourceId: Int64, trackId: Int64) {
        let source = try await store.insertSource(
            Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                   title: sourceTitle, addedAt: Date(), lastResolvedAt: nil,
                   followUpdates: false, licenseText: nil, memberCapHit: false,
                   localIsFolder: false, artworkTrackId: nil))
        let sourceId = try XCTUnwrap(source.id)
        let track = try await store.insertTrack(
            Track(id: nil, albumId: nil, sourceId: sourceId, title: "Track",
                  trackNo: 1, discNo: nil, durationSec: nil, codec: nil,
                  sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "a"))
        let trackId = try XCTUnwrap(track.id)
        return (sourceId, trackId)
    }

    func testNoCustomArtworkReturnsNil() async throws {
        let store = try makeStore()
        let ids = try await seedTrack(store)
        let result = try await store.customArtworkId(for: ids.trackId)
        XCTAssertNil(result)
    }

    func testSetAndReadCustomArtwork() async throws {
        let store = try makeStore()
        let ids = try await seedTrack(store)
        try await store.setCustomArtwork(trackId: ids.trackId, artworkId: "abc")
        let read = try await store.customArtworkId(for: ids.trackId)
        XCTAssertEqual(read, "abc")
    }

    func testUpsertUpdatesArtworkId() async throws {
        let store = try makeStore()
        let ids = try await seedTrack(store)
        try await store.setCustomArtwork(trackId: ids.trackId, artworkId: "abc")
        try await store.setCustomArtwork(trackId: ids.trackId, artworkId: "def")
        let read = try await store.customArtworkId(for: ids.trackId)
        XCTAssertEqual(read, "def")
        let allCount = try await store.allCustomArtworkIds().count
        XCTAssertEqual(allCount, 1)
    }

    func testDeleteCustomArtwork() async throws {
        let store = try makeStore()
        let ids = try await seedTrack(store)
        try await store.setCustomArtwork(trackId: ids.trackId, artworkId: "abc")
        try await store.deleteCustomArtwork(trackId: ids.trackId)
        let read = try await store.customArtworkId(for: ids.trackId)
        XCTAssertNil(read)
    }

    func testCustomArtworkIdsForSource() async throws {
        let store = try makeStore()
        let ids = try await seedTrack(store)
        try await store.setCustomArtwork(trackId: ids.trackId, artworkId: "abc")
        let forSource = try await store.customArtworkIds(forSource: ids.sourceId)
        XCTAssertEqual(forSource, ["abc"])
    }

    func testClearAllCustomArtwork() async throws {
        let store = try makeStore()
        let a = try await seedTrack(store, sourceTitle: "A")
        let b = try await seedTrack(store, sourceTitle: "B")
        try await store.setCustomArtwork(trackId: a.trackId, artworkId: "1")
        try await store.setCustomArtwork(trackId: b.trackId, artworkId: "2")
        try await store.clearAllCustomArtwork()
        let count = try await store.allCustomArtworkIds().count
        XCTAssertEqual(count, 0)
    }

    func testSourceDeletionCascadesCustomArtwork() async throws {
        let store = try makeStore()
        let ids = try await seedTrack(store)
        try await store.setCustomArtwork(trackId: ids.trackId, artworkId: "abc")
        try await store.deleteSource(id: ids.sourceId)
        let count = try await store.allCustomArtworkIds().count
        XCTAssertEqual(count, 0)
    }
}
