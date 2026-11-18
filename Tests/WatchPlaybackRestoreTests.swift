import Foundation
import Testing
import TonearmWatchCore

/// Phase 9a — deterministic shuffle persistence and queue restoration with missing files.
@Suite struct WatchPlaybackRestoreTests {

    // MARK: - Deterministic shuffle

    @Test func testShuffleIsDeterministicForASeed() {
        var a = WatchPlayerEngine(queue: ["1", "2", "3", "4", "5", "6", "7", "8"])
        var b = WatchPlayerEngine(queue: ["1", "2", "3", "4", "5", "6", "7", "8"])
        a.setShuffle(true, seed: 0xABCD_1234)
        b.setShuffle(true, seed: 0xABCD_1234)
        #expect(a.queue == b.queue)
        #expect(a.queue != ["1", "2", "3", "4", "5", "6", "7", "8"],
                          "an 8-track queue should actually be reordered")
    }

    @Test func testDifferentSeedsGiveDifferentOrders() {
        var a = WatchPlayerEngine(queue: Array(1...12).map(String.init))
        var b = WatchPlayerEngine(queue: Array(1...12).map(String.init))
        a.setShuffle(true, seed: 1)
        b.setShuffle(true, seed: 2)
        #expect(a.queue != b.queue)
    }

    @Test func testShuffleKeepsCurrentTrackFirst() {
        var engine = WatchPlayerEngine(queue: ["a", "b", "c", "d"], startIndex: 2)
        engine.setShuffle(true, seed: 99)
        #expect(engine.currentTrack == "c")
        #expect(engine.currentIndex == 0)
    }

    @Test func testSnapshotCarriesShuffleAndRepeat() {
        var engine = WatchPlayerEngine(queue: ["a", "b", "c"])
        engine.cycleRepeat() // all
        engine.setShuffle(true, seed: 77)
        let snap = engine.snapshot
        #expect(snap.isShuffled)
        #expect(snap.shuffleSeed == 77)
        #expect(snap.repeatMode == .all)
    }

    @Test func testSnapshotRoundTripsThroughJSON() throws {
        var engine = WatchPlayerEngine(queue: ["a", "b"], startIndex: 1)
        engine.cycleRepeat(); engine.cycleRepeat() // one
        engine.setShuffle(true, seed: 555)
        let data = try JSONEncoder().encode(engine.snapshot)
        let decoded = try JSONDecoder().decode(WatchQueueSnapshot.self, from: data)
        #expect(decoded == engine.snapshot)
    }

    @Test func testLegacySnapshotJSONWithoutNewKeysDecodes() throws {
        let legacy = #"{"trackKeys":["x","y"],"currentIndex":1,"elapsed":12.5,"isPlaying":true}"#
        let decoded = try JSONDecoder().decode(WatchQueueSnapshot.self,
                                               from: Data(legacy.utf8))
        #expect(decoded.trackKeys == ["x", "y"])
        #expect(decoded.currentIndex == 1)
        #expect(decoded.elapsed == 12.5)
        #expect(!decoded.isShuffled)
        #expect(decoded.shuffleSeed == 0)
        #expect(decoded.repeatMode == .off)
    }

    // MARK: - Restoration with missing files

    @Test func testRestoreDropsMissingTracksAndRemapsIndex() {
        let snap = WatchQueueSnapshot(trackKeys: ["a", "b", "c", "d", "e"], currentIndex: 3,
                                      elapsed: 40, isPlaying: true, repeatMode: .all)
        let engine = WatchPlayerEngine.restored(from: snap, availableKeys: ["a", "c", "d"])
        #expect(engine.queue == ["a", "c", "d"])
        #expect(engine.currentTrack == "d")
        #expect(engine.elapsed == 40, "the current track survived, so its position is kept")
        #expect(!engine.isPlaying, "restore is always paused")
        #expect(engine.repeatMode == .all)
    }

    @Test func testRestoreWhenCurrentTrackVanishedMovesToNextAvailable() {
        let snap = WatchQueueSnapshot(trackKeys: ["a", "b", "c", "d"], currentIndex: 1,
                                      elapsed: 30, isPlaying: true)
        let engine = WatchPlayerEngine.restored(from: snap, availableKeys: ["a", "c", "d"])
        #expect(engine.currentTrack == "c")
        #expect(engine.elapsed == 0, "the saved position belonged to a track that is gone")
    }

    @Test func testRestoreWhenNoTracksSurviveIsEmpty() {
        let snap = WatchQueueSnapshot(trackKeys: ["a", "b"], currentIndex: 0, elapsed: 10)
        let engine = WatchPlayerEngine.restored(from: snap, availableKeys: [])
        #expect(engine.queue.isEmpty)
        #expect(engine.currentTrack == nil)
        #expect(engine.elapsed == 0)
    }

    @Test func testRestoreWhenOnlyTrailingTracksVanishClampsToLast() {
        let snap = WatchQueueSnapshot(trackKeys: ["a", "b", "c"], currentIndex: 2, elapsed: 5)
        let engine = WatchPlayerEngine.restored(from: snap, availableKeys: ["a", "b"])
        #expect(engine.currentTrack == "b")
        #expect(engine.elapsed == 0)
    }

    @Test func testRestorePreservesShuffleSeedForSameOrder() {
        var live = WatchPlayerEngine(queue: Array(1...10).map(String.init))
        live.setShuffle(true, seed: 4242)
        let restored = WatchPlayerEngine.restored(
            from: live.snapshot,
            availableKeys: Set(live.queue))
        #expect(restored.queue == live.queue)
        #expect(restored.isShuffled)
        #expect(restored.shuffleSeed == 4242)
    }
}
