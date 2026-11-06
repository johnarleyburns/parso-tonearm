import XCTest
import GRDB
@testable import TonearmCore

/// Documents the DB-level invariant behind the Google-Drive "favorited and played a track but it
/// never showed up in Favorites or Jump Back In" bug fix: both `favorite.trackId` and
/// `play_history.trackId` have a foreign key to `track(id)`, so writing against a transient,
/// not-yet-persisted id (a browsed-but-never-imported remote row's negative `TrackRow.id`) must
/// fail rather than silently landing on an id that will never become the track's real, lasting
/// one — exactly the same invariant `Tests/CustomArtworkTests.swift` already documents for
/// `custom_artwork.trackId`. This is why `AppState.toggleFavorite` and
/// `SourceDetailView+Remote.swift`'s `playRemote` now persist the row first (see the source-
/// inspection tests in `FavoriteAndHistoryGuardOrderingTests` below for that ordering, since
/// exercising those AppState-level call sites directly would need a live remote provider).
final class FavoriteAndHistoryTransientTrackTests: XCTestCase {
    private func makeStore() throws -> LibraryStore {
        try LibraryStore(inMemory: true)
    }

    private func seedTrack(_ store: LibraryStore, sourceTitle: String = "Src") async throws -> Int64 {
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
        return try XCTUnwrap(track.id)
    }

    func testRecordPlayFailsForATransientNonExistentTrackId() async throws {
        let store = try makeStore()
        let transientId: Int64 = -1
        XCTAssertThrowsError(try store.recordPlay(trackId: transientId),
            "expected a foreign-key violation for a transient/non-existent trackId")
        let recent = try store.recentlyPlayedRows()
        XCTAssertTrue(recent.isEmpty)
    }

    func testSetFavoriteFailsForATransientNonExistentTrackId() async throws {
        let store = try makeStore()
        let transientId: Int64 = -1
        XCTAssertThrowsError(try store.setFavorite(trackId: transientId, true),
            "expected a foreign-key violation for a transient/non-existent trackId")
        let favorites = try store.favoriteRows()
        XCTAssertTrue(favorites.isEmpty)
    }

    /// The positive path, once the track is a real, persisted row (exactly what
    /// `persistRemoteTrack` produces before these writes now happen).
    func testRecordPlayAndSetFavoriteSucceedOncePersisted() async throws {
        let store = try makeStore()
        let trackId = try await seedTrack(store)

        try store.recordPlay(trackId: trackId)
        let recent = try store.recentlyPlayedRows()
        XCTAssertEqual(recent.map(\.id), [trackId])

        try store.setFavorite(trackId: trackId, true)
        let favorites = try store.favoriteRows()
        XCTAssertEqual(favorites.map(\.id), [trackId])
    }
}

/// Source-inspection coverage for the two AppState/UI-layer call sites, mirroring the
/// established pattern in `Tests/WatchAVPlayerItemTests.swift` for the same class of bug —
/// exercising these directly would need a live remote provider (Google Drive OAuth, a real
/// folder listing), so this pins the actual persist-before-write/play ordering in source instead,
/// per CLAUDE.md's "narrowest reliable alternative" when full automated coverage isn't practical.
final class FavoriteAndHistoryGuardOrderingTests: XCTestCase {
    func testToggleFavoritePersistsATransientRowFirstAndNeverOptimisticallyUpdatesOnFailure() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/App/AppState+FavoritesPlaylists.swift"),
            encoding: .utf8)
        let persist = try XCTUnwrap(source.range(of: "if target.id < 0 {"))
        let write = try XCTUnwrap(source.range(of: "try await store.setFavorite(trackId: target.id, makeFavorite)"))
        XCTAssertLessThan(persist.lowerBound, write.lowerBound,
            "a transient row's id must be persisted before writing the favorite")
        XCTAssertFalse(source.contains("try? await store.setFavorite"),
            "the write must not swallow a failure and then optimistically update favoriteIds anyway")
    }

    func testPlayRemotePersistsTheStartingTrackBeforeHandingOffToThePlayer() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Sources/SourceDetailView+Remote.swift"),
            encoding: .utf8)
        let persist = try XCTUnwrap(source.range(of: "await appState.persistRemoteTrack(rows[startIndex])"))
        let play = try XCTUnwrap(source.range(of: "player.play(tracks: rows, startAt: startIndex"))
        XCTAssertLessThan(persist.lowerBound, play.lowerBound,
            "the starting track must be persisted before playback begins, so its play history/favorite can be recorded")
    }
}
