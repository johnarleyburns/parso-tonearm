import XCTest
@testable import TonearmCore

final class WatchPlayerEngineTests: XCTestCase {

    func urlMap(_ track: String) -> URL? {
        URL(fileURLWithPath: "/tmp/\(track).mp3")
    }

    func testInitialState() {
        let engine = WatchPlayerEngine()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(engine.repeatMode, .off)
        XCTAssertEqual(engine.elapsed, 0)
        XCTAssertNil(engine.currentTrack)
        XCTAssertFalse(engine.canPlayNext)
        XCTAssertFalse(engine.canPlayPrevious)
    }

    func testPlayEmitsDirectives() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        let directives = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(directives, [.loadItem(urlMap("t1")!), .play])
        XCTAssertTrue(engine.isPlaying)
    }

    func testPlayWithMissingURLReturnsEmpty() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        let directives = engine.command(.play, urlForTrack: { _ in nil })
        XCTAssertTrue(directives.isEmpty)
        XCTAssertFalse(engine.isPlaying)
    }

    func testPauseEmitsPause() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        let directives = engine.command(.pause)
        XCTAssertEqual(directives, [.pause])
        XCTAssertFalse(engine.isPlaying)
    }

    func testTogglePlayPause() {
        var engine = WatchPlayerEngine(queue: ["t1"])

        let d1 = engine.command(.togglePlayPause, urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(d1.last, .play)
        XCTAssertTrue(engine.isPlaying)

        let d2 = engine.command(.togglePlayPause)
        XCTAssertEqual(d2.last, .pause)
        XCTAssertFalse(engine.isPlaying)
    }

    func testNextAdvancesTrack() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(engine.currentTrack, "t1")

        let directives = engine.command(.next, urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(engine.currentTrack, "t2")
        XCTAssertEqual(engine.currentIndex, 1)
        XCTAssertEqual(directives.last, .play)
    }

    func testNextAtEndWithRepeatOffGoesToLastTrack() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        let directives = engine.command(.next, urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(directives.last, .play) // stays on last track
    }

    func testNextAtEndWithRepeatAllWraps() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"], startIndex: 1)
        engine.cycleRepeat()  // off → all
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(engine.currentTrack, "t2")

        let directives = engine.command(.next, urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(engine.currentTrack, "t1")
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(directives.last, .play)
    }

    func testRepeatOneReplaysSameTrack() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"])
        engine.cycleRepeat() // off → all
        engine.cycleRepeat() // all → one
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })

        let directives = engine.command(.next, urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(engine.currentTrack, "t1", "repeat one should stay on same track")
        XCTAssertEqual(engine.elapsed, 0)
        XCTAssertEqual(directives.last, .play)
    }

    func testPreviousWithin3SecondsRestarts() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"], startIndex: 1)
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        _ = engine.command(.seek(to: 2.0))

        let directives = engine.command(.previous, urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(engine.currentTrack, "t2", "under 3s should restart current")
        XCTAssertEqual(engine.elapsed, 0)
        XCTAssertEqual(directives.last, .play)
    }

    func testPreviousAfter3SecondsGoesBack() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"], startIndex: 1)
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        _ = engine.command(.seek(to: 5.0))

        let directives = engine.command(.previous, urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(engine.currentTrack, "t1", "over 3s should go to previous")
        XCTAssertEqual(directives.last, .play)
    }

    func testCycleRepeat() {
        var engine = WatchPlayerEngine()
        XCTAssertEqual(engine.repeatMode, .off)
        engine.cycleRepeat()
        XCTAssertEqual(engine.repeatMode, .all)
        engine.cycleRepeat()
        XCTAssertEqual(engine.repeatMode, .one)
        engine.cycleRepeat()
        XCTAssertEqual(engine.repeatMode, .off)
    }

    func testToggleShuffle() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2", "t3"])
        XCTAssertFalse(engine.isShuffled)
        engine.toggleShuffle()
        XCTAssertTrue(engine.isShuffled)
        XCTAssertEqual(engine.currentIndex, 0)
        XCTAssertEqual(engine.queue.count, 3)
    }

    func testSetQueue() {
        var engine = WatchPlayerEngine()
        engine.setQueue(["a", "b", "c"], startIndex: 1)
        XCTAssertEqual(engine.queue, ["a", "b", "c"])
        XCTAssertEqual(engine.currentIndex, 1)
        XCTAssertEqual(engine.elapsed, 0)
        XCTAssertEqual(engine.currentTrack, "b")
    }

    func testJumpToTrack() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2", "t3"])
        let directives = engine.command(.jump(to: 2), urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(engine.currentTrack, "t3")
        XCTAssertEqual(engine.currentIndex, 2)
        XCTAssertEqual(directives.first, .loadItem(urlMap("t3")!))
        XCTAssertEqual(directives.last, .play)
    }

    func testSeek() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        let directives = engine.command(.seek(to: 30.0))
        XCTAssertEqual(engine.elapsed, 30.0)
        XCTAssertEqual(directives, [.seek(to: 30.0)])
    }

    func testItemEndedAutoAdvance() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        let directives = engine.command(.itemEnded, urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(engine.currentTrack, "t2")
        XCTAssertEqual(directives.last, .play)
    }

    func testItemEndedAtEndOfQueueStops() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        let directives = engine.command(.itemEnded, urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(directives, [.stop])
        XCTAssertFalse(engine.isPlaying)
    }

    func testItemFailedSkipsToNext() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        let directives = engine.command(.itemFailed, urlForTrack: { [self] in urlMap($0) })
        XCTAssertEqual(engine.currentTrack, "t2")
        XCTAssertEqual(directives.last, .play)
    }

    func testRouteLostPauses() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        let directives = engine.command(.routeLost)
        XCTAssertEqual(directives, [.pause])
        XCTAssertFalse(engine.isPlaying)
    }

    func testSnapshot() {
        var engine = WatchPlayerEngine(queue: ["a", "b", "c"], startIndex: 1)
        _ = engine.command(.seek(to: 15.0))
        let snap = engine.snapshot
        XCTAssertEqual(snap.trackKeys, ["a", "b", "c"])
        XCTAssertEqual(snap.currentIndex, 1)
        XCTAssertEqual(snap.elapsed, 15.0)
        XCTAssertFalse(snap.isPlaying)
    }
}
