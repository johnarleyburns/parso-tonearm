import XCTest
import TonearmWatchCore

/// Phase 9a — deterministic shuffle persistence and queue restoration with missing files.
final class WatchPlaybackRestoreTests: XCTestCase {

    // MARK: - Deterministic shuffle

    func testShuffleIsDeterministicForASeed() {
        var a = WatchPlayerEngine(queue: ["1", "2", "3", "4", "5", "6", "7", "8"])
        var b = WatchPlayerEngine(queue: ["1", "2", "3", "4", "5", "6", "7", "8"])
        a.setShuffle(true, seed: 0xABCD_1234)
        b.setShuffle(true, seed: 0xABCD_1234)
        XCTAssertEqual(a.queue, b.queue)
        XCTAssertNotEqual(a.queue, ["1", "2", "3", "4", "5", "6", "7", "8"],
                          "an 8-track queue should actually be reordered")
    }

    func testDifferentSeedsGiveDifferentOrders() {
        var a = WatchPlayerEngine(queue: Array(1...12).map(String.init))
        var b = WatchPlayerEngine(queue: Array(1...12).map(String.init))
        a.setShuffle(true, seed: 1)
        b.setShuffle(true, seed: 2)
        XCTAssertNotEqual(a.queue, b.queue)
    }

    func testShuffleKeepsCurrentTrackFirst() {
        var engine = WatchPlayerEngine(queue: ["a", "b", "c", "d"], startIndex: 2)
        engine.setShuffle(true, seed: 99)
        XCTAssertEqual(engine.currentTrack, "c")
        XCTAssertEqual(engine.currentIndex, 0)
    }

    func testSnapshotCarriesShuffleAndRepeat() {
        var engine = WatchPlayerEngine(queue: ["a", "b", "c"])
        engine.cycleRepeat() // all
        engine.setShuffle(true, seed: 77)
        let snap = engine.snapshot
        XCTAssertTrue(snap.isShuffled)
        XCTAssertEqual(snap.shuffleSeed, 77)
        XCTAssertEqual(snap.repeatMode, .all)
    }

    func testSnapshotRoundTripsThroughJSON() throws {
        var engine = WatchPlayerEngine(queue: ["a", "b"], startIndex: 1)
        engine.cycleRepeat(); engine.cycleRepeat() // one
        engine.setShuffle(true, seed: 555)
        let data = try JSONEncoder().encode(engine.snapshot)
        let decoded = try JSONDecoder().decode(WatchQueueSnapshot.self, from: data)
        XCTAssertEqual(decoded, engine.snapshot)
    }

    func testLegacySnapshotJSONWithoutNewKeysDecodes() throws {
        let legacy = #"{"trackKeys":["x","y"],"currentIndex":1,"elapsed":12.5,"isPlaying":true}"#
        let decoded = try JSONDecoder().decode(WatchQueueSnapshot.self,
                                               from: Data(legacy.utf8))
        XCTAssertEqual(decoded.trackKeys, ["x", "y"])
        XCTAssertEqual(decoded.currentIndex, 1)
        XCTAssertEqual(decoded.elapsed, 12.5)
        XCTAssertFalse(decoded.isShuffled)
        XCTAssertEqual(decoded.shuffleSeed, 0)
        XCTAssertEqual(decoded.repeatMode, .off)
    }

    // MARK: - Restoration with missing files

    func testRestoreDropsMissingTracksAndRemapsIndex() {
        let snap = WatchQueueSnapshot(trackKeys: ["a", "b", "c", "d", "e"], currentIndex: 3,
                                      elapsed: 40, isPlaying: true, repeatMode: .all)
        let engine = WatchPlayerEngine.restored(from: snap, availableKeys: ["a", "c", "d"])
        XCTAssertEqual(engine.queue, ["a", "c", "d"])
        XCTAssertEqual(engine.currentTrack, "d")
        XCTAssertEqual(engine.elapsed, 40, "the current track survived, so its position is kept")
        XCTAssertFalse(engine.isPlaying, "restore is always paused")
        XCTAssertEqual(engine.repeatMode, .all)
    }

    func testRestoreWhenCurrentTrackVanishedMovesToNextAvailable() {
        let snap = WatchQueueSnapshot(trackKeys: ["a", "b", "c", "d"], currentIndex: 1,
                                      elapsed: 30, isPlaying: true)
        let engine = WatchPlayerEngine.restored(from: snap, availableKeys: ["a", "c", "d"])
        XCTAssertEqual(engine.currentTrack, "c")
        XCTAssertEqual(engine.elapsed, 0, "the saved position belonged to a track that is gone")
    }

    func testRestoreWhenNoTracksSurviveIsEmpty() {
        let snap = WatchQueueSnapshot(trackKeys: ["a", "b"], currentIndex: 0, elapsed: 10)
        let engine = WatchPlayerEngine.restored(from: snap, availableKeys: [])
        XCTAssertTrue(engine.queue.isEmpty)
        XCTAssertNil(engine.currentTrack)
        XCTAssertEqual(engine.elapsed, 0)
    }

    func testRestoreWhenOnlyTrailingTracksVanishClampsToLast() {
        let snap = WatchQueueSnapshot(trackKeys: ["a", "b", "c"], currentIndex: 2, elapsed: 5)
        let engine = WatchPlayerEngine.restored(from: snap, availableKeys: ["a", "b"])
        XCTAssertEqual(engine.currentTrack, "b")
        XCTAssertEqual(engine.elapsed, 0)
    }

    func testRestorePreservesShuffleSeedForSameOrder() {
        var live = WatchPlayerEngine(queue: Array(1...10).map(String.init))
        live.setShuffle(true, seed: 4242)
        let restored = WatchPlayerEngine.restored(
            from: live.snapshot,
            availableKeys: Set(live.queue))
        XCTAssertEqual(restored.queue, live.queue)
        XCTAssertTrue(restored.isShuffled)
        XCTAssertEqual(restored.shuffleSeed, 4242)
    }
}
