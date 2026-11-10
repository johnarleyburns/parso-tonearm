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
        do {
            try await store.recordPlay(trackId: transientId)
            XCTFail("expected a foreign-key violation for a transient/non-existent trackId")
        } catch {
            // Expected: GRDB surfaces the FK constraint failure.
        }
        let recent = try await store.recentlyPlayedRows()
        XCTAssertTrue(recent.isEmpty)
    }

    func testSetFavoriteFailsForATransientNonExistentTrackId() async throws {
        let store = try makeStore()
        let transientId: Int64 = -1
        do {
            try await store.setFavorite(trackId: transientId, true)
            XCTFail("expected a foreign-key violation for a transient/non-existent trackId")
        } catch {
            // Expected: GRDB surfaces the FK constraint failure.
        }
        let favorites = try await store.favoriteRows()
        XCTAssertTrue(favorites.isEmpty)
    }

    /// The positive path, once the track is a real, persisted row (exactly what
    /// `persistRemoteTrack` produces before these writes now happen).
    func testRecordPlayAndSetFavoriteSucceedOncePersisted() async throws {
        let store = try makeStore()
        let trackId = try await seedTrack(store)

        try await store.recordPlay(trackId: trackId)
        let recent = try await store.recentlyPlayedRows()
        XCTAssertEqual(recent.map(\.id), [trackId])

        try await store.setFavorite(trackId: trackId, true)
        let favorites = try await store.favoriteRows()
        XCTAssertEqual(favorites.map(\.id), [trackId])
    }

    func testClearPlayHistoryEmptiesBothRecentlyPlayedAndTheRawEventLog() async throws {
        let store = try makeStore()
        let trackId = try await seedTrack(store)
        try await store.recordPlay(trackId: trackId)
        try await store.recordPlay(trackId: trackId)
        let recentBefore = try await store.recentlyPlayedRows()
        XCTAssertFalse(recentBefore.isEmpty)
        let eventsBefore = try await store.allPlayEvents()
        XCTAssertFalse(eventsBefore.isEmpty)

        try await store.clearPlayHistory()

        let recentAfter = try await store.recentlyPlayedRows()
        XCTAssertTrue(recentAfter.isEmpty, "Jump Back In must be empty after clearing")
        let eventsAfter = try await store.allPlayEvents()
        XCTAssertTrue(eventsAfter.isEmpty, "Listening Stats' event source is also emptied (disclosed side effect)")
    }

    func testClearPlayHistoryLeavesFavoritesAndTracksUntouched() async throws {
        let store = try makeStore()
        let trackId = try await seedTrack(store)
        try await store.recordPlay(trackId: trackId)
        try await store.setFavorite(trackId: trackId, true)
        try await store.clearPlayHistory()
        let favorites = try await store.favoriteRows()
        XCTAssertEqual(favorites.count, 1, "clearing play history must not touch favorites")
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
        let persist = try XCTUnwrap(source.range(of: "await appState.persistRemoteTrack(rows[startIndex], prefetchBytes: false)"))
        let play = try XCTUnwrap(source.range(of: "player.play(tracks: rows, startAt: startIndex"))
        XCTAssertLessThan(persist.lowerBound, play.lowerBound,
            "the starting track must be persisted before playback begins, so its play history/favorite can be recorded")
    }

    /// Real report: re-browsing to and replaying/favoriting the same remote file in quick
    /// succession (a double-tap, or tapping again before the first attempt's feedback arrives)
    /// could run two `persistRemoteTrack` calls for the same provider node concurrently, neither
    /// seeing the other's not-yet-committed insert — a genuine duplicate track. Pins that a
    /// second call for the same identity key awaits the first one's own in-flight work, rather
    /// than exercising the real race directly (needs a live remote provider + precise timing, per
    /// this file's own established pattern above).
    func testPersistRemoteTrackAwaitsAnInFlightCallForTheSameIdentityInsteadOfRacingIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/App/AppState+Downloads.swift"),
            encoding: .utf8)
        let guardCheck = try XCTUnwrap(source.range(of: "if let inFlight = pendingRemotePersists[identityKey]"))
        let awaitExisting = try XCTUnwrap(source.range(of: "return await inFlight.value"))
        let startNewTask = try XCTUnwrap(source.range(of: "pendingRemotePersists[identityKey] = task"))
        let cleanup = try XCTUnwrap(source.range(of: "pendingRemotePersists[identityKey] = nil"))
        XCTAssertLessThan(guardCheck.lowerBound, awaitExisting.lowerBound,
            "an in-flight call for the same identity must be checked and awaited, not re-started")
        XCTAssertLessThan(awaitExisting.lowerBound, startNewTask.lowerBound,
            "the in-flight-await branch must come before a new task is ever registered")
        XCTAssertLessThan(startNewTask.lowerBound, cleanup.lowerBound,
            "the identity key must be cleared again after the new task finishes, or every later call for it would hang")
    }
}

final class JumpBackInClearSourceTests: XCTestCase {
    private func listenSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Features/Listen/ListenView.swift"),
                          encoding: .utf8)
    }

    func testJumpBackInClearButtonExistsCallsClearPlayHistoryAndIsConfirmedBeforeDestroying() throws {
        let source = try listenSource()
        XCTAssertTrue(source.contains("\"listen.recent.clear\""))
        XCTAssertTrue(source.contains("\"listen.recent.clearConfirm\""))
        XCTAssertTrue(source.contains("store.clearPlayHistory()"))
        XCTAssertTrue(source.contains("role: .destructive"))
        XCTAssertTrue(source.contains(".sensoryFeedback(.warning, trigger: showClearRecentConfirm)"))
        let clearButton = try XCTUnwrap(source.range(of: "\"listen.recent.clear\""))
        let destructiveCall = try XCTUnwrap(source.range(of: "store.clearPlayHistory()"))
        XCTAssertLessThan(clearButton.lowerBound, destructiveCall.lowerBound)
    }

    func testFavoritesCardRowCallSiteDoesNotOptIntoClear() throws {
        let source = try listenSource()
        let start = try XCTUnwrap(source.range(of: "cardRow(title: \"Favorites\", rows: appState.favoriteRows,"))
        let end = try XCTUnwrap(source.range(of: "showNeverRecommend: true)",
                                range: start.lowerBound..<source.endIndex))
        XCTAssertFalse(source[start.lowerBound..<end.upperBound].contains("onClear:"))
    }
}

final class JumpBackInDismissalTests: XCTestCase {
    private func seed(_ store: LibraryStore) async throws -> Int64 {
        let source = try await store.insertSource(
            Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                   title: "Src", addedAt: Date(), lastResolvedAt: nil,
                   followUpdates: false, licenseText: nil, memberCapHit: false,
                   localIsFolder: false, artworkTrackId: nil))
        let track = try await store.insertTrack(
            Track(id: nil, albumId: nil, sourceId: try XCTUnwrap(source.id), title: "Track",
                  trackNo: 1, discNo: nil, durationSec: nil, codec: nil,
                  sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "a"))
        return try XCTUnwrap(track.id)
    }

    func testDismissedTrackIsExcludedFromJumpBackIn() async throws {
        let store = try LibraryStore(inMemory: true)
        let id = try await seed(store)
        try await store.recordPlay(trackId: id)
        var rows = try await store.recentlyPlayedRows()
        XCTAssertEqual(rows.map(\.id), [id])
        try await store.dismissFromJumpBackIn(trackId: id)
        rows = try await store.recentlyPlayedRows()
        XCTAssertTrue(rows.isEmpty)
    }

    func testPlayingADismissedTrackAgainBringsItBackToJumpBackIn() async throws {
        let store = try LibraryStore(inMemory: true)
        let id = try await seed(store)
        try await store.recordPlay(trackId: id)
        try await store.dismissFromJumpBackIn(trackId: id)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await store.recordPlay(trackId: id)
        let rows = try await store.recentlyPlayedRows()
        XCTAssertEqual(rows.map(\.id), [id])
    }

    func testDismissalNeverTouchesPlayHistoryOrListeningStats() async throws {
        let store = try LibraryStore(inMemory: true)
        let id = try await seed(store)
        try await store.recordPlay(trackId: id)
        try await store.recordPlay(trackId: id)
        let before = try await store.allPlayEvents()
        try await store.dismissFromJumpBackIn(trackId: id)
        let after = try await store.allPlayEvents()
        XCTAssertEqual(before, after)
        XCTAssertEqual(after.count, 2)
    }

    func testRedismissingAnAlreadyDismissedTrackUpsertsRatherThanDuplicating() async throws {
        let store = try LibraryStore(inMemory: true)
        let id = try await seed(store)
        try await store.recordPlay(trackId: id)
        try await store.dismissFromJumpBackIn(trackId: id)
        try await store.dismissFromJumpBackIn(trackId: id)
        let count = try await store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jump_back_in_dismissal WHERE trackId = ?",
                             arguments: [id])
        }
        XCTAssertEqual(count, 1)
    }

    func testWiringIsInPlace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: root.appendingPathComponent(p), encoding: .utf8) }
        let app = try src("Sources/App/AppState+FavoritesPlaylists.swift")
        let fn = try XCTUnwrap(app.range(of: "func dismissFromJumpBackIn(_ row: TrackRow) async {"))
        let body = String(app[fn.lowerBound...].prefix(400))
        XCTAssertTrue(body.contains("guard row.id > 0"))
        XCTAssertTrue(body.contains("store.dismissFromJumpBackIn(trackId: row.id)"))
        XCTAssertTrue(body.contains("recentlyPlayed = (try? await store.recentlyPlayedRows())"))
        XCTAssertFalse(body.contains("reload()"))
        let comp = try src("Sources/Features/Components.swift")
        XCTAssertTrue(comp.contains("showRemoveFromJumpBackIn"))
        XCTAssertTrue(comp.contains("appState.dismissFromJumpBackIn(row)"))
        XCTAssertTrue(comp.contains("listen.recent.removeRow"))
        let listen = try src("Sources/Features/Listen/ListenView.swift")
        XCTAssertTrue(listen.contains(#"showRemoveFromJumpBackIn: identifier == "listen.recent""#))
    }
}

final class MoodPromptCommitSourceTests: XCTestCase {
    func testMoodPromptBindsToLocalDraftAndOnlyCommitsOnSubmit() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Features/Listen/ListenView.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("text: $promptDraft)"))
        XCTAssertFalse(source.contains("text: promptBinding"))
        XCTAssertTrue(source.contains(".onSubmit { moodModel.searchText = promptDraft }"))
        XCTAssertFalse(source.contains("promptDraft = newValue\n                moodModel.searchText = newValue"))
    }
}

final class MoodPlayQueueSourceTests: XCTestCase {
    func testMoodPlayButtonSaysPlayMoodAndOpensNowPlaying() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Features/Listen/ListenView.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("\"Play Mood\", systemImage"))
        XCTAssertFalse(source.contains("\"Play\", systemImage"))
        XCTAssertTrue(source.contains("} else {\n            appState.showNowPlaying = true"))
    }

    func testPlayMoodPassesMoodQueueSourceNotLibrary() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Features/Listen/ListenView.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func playMood() async"))
        let body = String(source[start.lowerBound...].prefix(1200))
        XCTAssertTrue(body.contains("source: .mood(moodModel)"),
            "playMood() must hand the player .mood(moodModel) so queue extension and 'Include in current mood' reach the running query")
        XCTAssertFalse(body.contains("source: .library"))
    }
}
