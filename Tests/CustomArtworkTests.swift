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

    /// Documents the DB-level invariant behind the remote-track custom-artwork
    /// bug fix: `custom_artwork.trackId` has a foreign key to `track(id)`, so
    /// writing against a transient/not-yet-persisted id (e.g. a browsed remote
    /// row's negative `TrackRow.id`) must fail rather than silently landing on
    /// an id that will never become the track's real, lasting one. This is why
    /// `AppState.assignCustomArtwork(toTrack:data:)` persists the row first.
    func testSetCustomArtworkFailsForNonExistentTrackId() async throws {
        let store = try makeStore()
        let transientId: Int64 = -1
        do {
            try await store.setCustomArtwork(trackId: transientId, artworkId: "abc")
            XCTFail("expected a foreign-key violation for a transient/non-existent trackId")
        } catch {
            // Expected: GRDB surfaces the FK constraint failure.
        }
        let read = try await store.customArtworkId(for: transientId)
        XCTAssertNil(read)
    }

    func testSourceDeletionCascadesCustomArtwork() async throws {
        let store = try makeStore()
        let ids = try await seedTrack(store)
        try await store.setCustomArtwork(trackId: ids.trackId, artworkId: "abc")
        try await store.deleteSource(id: ids.sourceId)
        let count = try await store.allCustomArtworkIds().count
        XCTAssertEqual(count, 0)
    }

    // MARK: - Album-level

    private func seedAlbum(_ store: LibraryStore, sourceTitle: String = "Src") async throws -> (sourceId: Int64, albumId: Int64) {
        let source = try await store.insertSource(
            Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                   title: sourceTitle, addedAt: Date(), lastResolvedAt: nil,
                   followUpdates: false, licenseText: nil, memberCapHit: false,
                   localIsFolder: false, artworkTrackId: nil))
        let sourceId = try XCTUnwrap(source.id)
        let album = try await store.insertAlbum(
            Album(id: nil, sourceId: sourceId, title: "Album", artist: "Artist"))
        let albumId = try XCTUnwrap(album.id)
        return (sourceId, albumId)
    }

    func testNoAlbumCustomArtworkReturnsNil() async throws {
        let store = try makeStore()
        let ids = try await seedAlbum(store)
        let result = try await store.albumCustomArtworkId(for: ids.albumId)
        XCTAssertNil(result)
    }

    func testSetGetDeleteAlbumCustomArtwork() async throws {
        let store = try makeStore()
        let ids = try await seedAlbum(store)
        try await store.setAlbumCustomArtwork(albumId: ids.albumId, artworkId: "album-art")
        var read = try await store.albumCustomArtworkId(for: ids.albumId)
        XCTAssertEqual(read, "album-art")

        try await store.setAlbumCustomArtwork(albumId: ids.albumId, artworkId: "album-art-2")
        read = try await store.albumCustomArtworkId(for: ids.albumId)
        XCTAssertEqual(read, "album-art-2")
        let allCount = try await store.allAlbumCustomArtworkIds().count
        XCTAssertEqual(allCount, 1)

        try await store.deleteAlbumCustomArtwork(albumId: ids.albumId)
        read = try await store.albumCustomArtworkId(for: ids.albumId)
        XCTAssertNil(read)
    }

    func testClearAllAlbumCustomArtwork() async throws {
        let store = try makeStore()
        let a = try await seedAlbum(store, sourceTitle: "A")
        let b = try await seedAlbum(store, sourceTitle: "B")
        try await store.setAlbumCustomArtwork(albumId: a.albumId, artworkId: "1")
        try await store.setAlbumCustomArtwork(albumId: b.albumId, artworkId: "2")
        try await store.clearAllAlbumCustomArtwork()
        let count = try await store.allAlbumCustomArtworkIds().count
        XCTAssertEqual(count, 0)
    }

    func testSourceDeletionCascadesAlbumCustomArtwork() async throws {
        let store = try makeStore()
        let ids = try await seedAlbum(store)
        try await store.setAlbumCustomArtwork(albumId: ids.albumId, artworkId: "abc")
        try await store.deleteSource(id: ids.sourceId)
        let count = try await store.allAlbumCustomArtworkIds().count
        XCTAssertEqual(count, 0)
    }

    // MARK: - Source-level

    func testNoSourceCustomArtworkReturnsNil() async throws {
        let store = try makeStore()
        let ids = try await seedTrack(store)
        let result = try await store.sourceCustomArtworkId(for: ids.sourceId)
        XCTAssertNil(result)
    }

    func testSetGetDeleteSourceCustomArtwork() async throws {
        let store = try makeStore()
        let ids = try await seedTrack(store)
        try await store.setSourceCustomArtwork(sourceId: ids.sourceId, artworkId: "source-art")
        var read = try await store.sourceCustomArtworkId(for: ids.sourceId)
        XCTAssertEqual(read, "source-art")

        try await store.setSourceCustomArtwork(sourceId: ids.sourceId, artworkId: "source-art-2")
        read = try await store.sourceCustomArtworkId(for: ids.sourceId)
        XCTAssertEqual(read, "source-art-2")
        let allCount = try await store.allSourceCustomArtworkIds().count
        XCTAssertEqual(allCount, 1)

        try await store.deleteSourceCustomArtwork(sourceId: ids.sourceId)
        read = try await store.sourceCustomArtworkId(for: ids.sourceId)
        XCTAssertNil(read)
    }

    func testClearAllSourceCustomArtwork() async throws {
        let store = try makeStore()
        let a = try await seedTrack(store, sourceTitle: "A")
        let b = try await seedTrack(store, sourceTitle: "B")
        try await store.setSourceCustomArtwork(sourceId: a.sourceId, artworkId: "1")
        try await store.setSourceCustomArtwork(sourceId: b.sourceId, artworkId: "2")
        try await store.clearAllSourceCustomArtwork()
        let count = try await store.allSourceCustomArtworkIds().count
        XCTAssertEqual(count, 0)
    }

    func testSourceDeletionCascadesSourceCustomArtwork() async throws {
        let store = try makeStore()
        let ids = try await seedTrack(store)
        try await store.setSourceCustomArtwork(sourceId: ids.sourceId, artworkId: "abc")
        try await store.deleteSource(id: ids.sourceId)
        let count = try await store.allSourceCustomArtworkIds().count
        XCTAssertEqual(count, 0)
    }
}
