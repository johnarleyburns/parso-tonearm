import Testing
@testable import TonearmCore

@Suite struct WatchPlayerEngineTests {

    func urlMap(_ track: String) -> URL? {
        URL(fileURLWithPath: "/tmp/\(track).mp3")
    }

    @Test func testInitialState() {
        let engine = WatchPlayerEngine()
        #expect(!engine.isPlaying)
        #expect(engine.repeatMode == .off)
        #expect(engine.elapsed == 0)
        #expect(engine.currentTrack == nil)
        #expect(!engine.canPlayNext)
        #expect(!engine.canPlayPrevious)
    }

    @Test func testPlayEmitsDirectives() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        let directives = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        #expect(directives == [.loadItem(urlMap("t1")!), .play])
        #expect(engine.isPlaying)
    }

    @Test func testPlayWithMissingURLReturnsEmpty() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        let directives = engine.command(.play, urlForTrack: { _ in nil })
        #expect(directives.isEmpty)
        #expect(!engine.isPlaying)
    }

    @Test func testPauseEmitsPause() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        let directives = engine.command(.pause)
        #expect(directives == [.pause])
        #expect(!engine.isPlaying)
    }

    @Test func testTogglePlayPause() {
        var engine = WatchPlayerEngine(queue: ["t1"])

        let d1 = engine.command(.togglePlayPause, urlForTrack: { [self] in urlMap($0) })
        #expect(d1.last == .play)
        #expect(engine.isPlaying)

        let d2 = engine.command(.togglePlayPause)
        #expect(d2.last == .pause)
        #expect(!engine.isPlaying)
    }

    @Test func testNextAdvancesTrack() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        #expect(engine.currentTrack == "t1")

        let directives = engine.command(.next, urlForTrack: { [self] in urlMap($0) })
        #expect(engine.currentTrack == "t2")
        #expect(engine.currentIndex == 1)
        #expect(directives.last == .play)
    }

    @Test func testNextAtEndWithRepeatOffGoesToLastTrack() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        let directives = engine.command(.next, urlForTrack: { [self] in urlMap($0) })
        #expect(directives.last == .play) // stays on last track
    }

    @Test func testNextAtEndWithRepeatAllWraps() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"], startIndex: 1)
        engine.cycleRepeat()  // off → all
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        #expect(engine.currentTrack == "t2")

        let directives = engine.command(.next, urlForTrack: { [self] in urlMap($0) })
        #expect(engine.currentTrack == "t1")
        #expect(engine.currentIndex == 0)
        #expect(directives.last == .play)
    }

    @Test func testRepeatOneReplaysSameTrack() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"])
        engine.cycleRepeat() // off → all
        engine.cycleRepeat() // all → one
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })

        let directives = engine.command(.next, urlForTrack: { [self] in urlMap($0) })
        #expect(engine.currentTrack == "t1", "repeat one should stay on same track")
        #expect(engine.elapsed == 0)
        #expect(directives.last == .play)
    }

    @Test func testPreviousWithin3SecondsRestarts() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"], startIndex: 1)
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        _ = engine.command(.seek(to: 2.0))

        let directives = engine.command(.previous, urlForTrack: { [self] in urlMap($0) })
        #expect(engine.currentTrack == "t2", "under 3s should restart current")
        #expect(engine.elapsed == 0)
        #expect(directives.last == .play)
    }

    @Test func testPreviousAfter3SecondsGoesBack() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"], startIndex: 1)
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        _ = engine.command(.seek(to: 5.0))

        let directives = engine.command(.previous, urlForTrack: { [self] in urlMap($0) })
        #expect(engine.currentTrack == "t1", "over 3s should go to previous")
        #expect(directives.last == .play)
    }

    @Test func testCycleRepeat() {
        var engine = WatchPlayerEngine()
        #expect(engine.repeatMode == .off)
        engine.cycleRepeat()
        #expect(engine.repeatMode == .all)
        engine.cycleRepeat()
        #expect(engine.repeatMode == .one)
        engine.cycleRepeat()
        #expect(engine.repeatMode == .off)
    }

    @Test func testToggleShuffle() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2", "t3"])
        #expect(!engine.isShuffled)
        engine.toggleShuffle()
        #expect(engine.isShuffled)
        #expect(engine.currentIndex == 0)
        #expect(engine.queue.count == 3)
    }

    @Test func testSetQueue() {
        var engine = WatchPlayerEngine()
        engine.setQueue(["a", "b", "c"], startIndex: 1)
        #expect(engine.queue == ["a", "b", "c"])
        #expect(engine.currentIndex == 1)
        #expect(engine.elapsed == 0)
        #expect(engine.currentTrack == "b")
    }

    @Test func testSetQueueClearsRequestedPlayingState() {
        var engine = WatchPlayerEngine(queue: ["old"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        #expect(engine.isPlaying)

        engine.setQueue(["new"])

        #expect(!engine.isPlaying)
        #expect(engine.currentTrack == "new")
    }

    @Test func testConfirmedPlayingCanReconcileAnOptimisticPlayRequest() {
        var engine = WatchPlayerEngine(queue: ["track"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        #expect(engine.isPlaying)

        engine.setConfirmedPlaying(false)

        #expect(!engine.isPlaying)
        #expect(!engine.snapshot.isPlaying)
    }

    @Test func testJumpToTrack() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2", "t3"])
        let directives = engine.command(.jump(to: 2), urlForTrack: { [self] in urlMap($0) })
        #expect(engine.currentTrack == "t3")
        #expect(engine.currentIndex == 2)
        #expect(directives.first == .loadItem(urlMap("t3")!))
        #expect(directives.last == .play)
    }

    @Test func testSeek() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        let directives = engine.command(.seek(to: 30.0))
        #expect(engine.elapsed == 30.0)
        #expect(directives == [.seek(to: 30.0)])
    }

    @Test func testItemEndedAutoAdvance() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        let directives = engine.command(.itemEnded, urlForTrack: { [self] in urlMap($0) })
        #expect(engine.currentTrack == "t2")
        #expect(directives.last == .play)
    }

    @Test func testItemEndedAtEndOfQueueStops() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        let directives = engine.command(.itemEnded, urlForTrack: { [self] in urlMap($0) })
        #expect(directives == [.stop])
        #expect(!engine.isPlaying)
    }

    @Test func testItemFailedSkipsToNext() {
        var engine = WatchPlayerEngine(queue: ["t1", "t2"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        let directives = engine.command(.itemFailed, urlForTrack: { [self] in urlMap($0) })
        #expect(engine.currentTrack == "t2")
        #expect(directives.last == .play)
    }

    @Test func testRouteLostPauses() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        let directives = engine.command(.routeLost)
        #expect(directives == [.pause])
        #expect(!engine.isPlaying)
    }

    @Test func testSnapshot() {
        var engine = WatchPlayerEngine(queue: ["a", "b", "c"], startIndex: 1)
        _ = engine.command(.seek(to: 15.0))
        let snap = engine.snapshot
        #expect(snap.trackKeys == ["a", "b", "c"])
        #expect(snap.currentIndex == 1)
        #expect(snap.elapsed == 15.0)
        #expect(!snap.isPlaying)
    }

    // MARK: - Live elapsed tracking (watch position lost on phone interrupt)
    //
    // Nothing but an explicit seek or a track change ever used to touch `elapsed` — it was frozen
    // at whatever the last command left it at, never the real, continuously-advancing playback
    // clock. `updateElapsed` is how the platform output's periodic time ticks keep the pure
    // engine's `elapsed` live, so ANY pause (a manual tap, a route loss when the phone's own
    // playback steals a shared Bluetooth route, an interruption) persists and resumes from the
    // position actually reached, not a stale value (frequently 0).

    @Test func testUpdateElapsedTracksTheLivePlaybackPosition() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        #expect(engine.elapsed == 0)

        engine.updateElapsed(12.4)
        #expect(engine.elapsed == 12.4)
        engine.updateElapsed(47.8)
        #expect(engine.elapsed == 47.8)
    }

    @Test func testPauseAfterLiveTimeUpdatesPersistsTheActualPositionNotAStaleOne() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        engine.updateElapsed(47.8)

        let directives = engine.command(.pause)

        #expect(directives == [.pause])
        #expect(engine.elapsed == 47.8, "pausing must capture the live position, not reset it")
        #expect(engine.snapshot.elapsed == 47.8,
                       "the persisted snapshot must carry the live position, too")
    }

    @Test func testResumingAfterAnAutomaticPauseStaysAtTheSamePosition() {
        // The exact shape of the reported bug: the watch's own playback of a track pauses itself —
        // here, because the phone starting a different track steals a shared Bluetooth route, which
        // `WatchPlayer.handleAudioEvent(.routeLost)` resolves to the same `.pause` engine command a
        // manual pause issues (`WatchAudioSessionPolicy.actions(for: .routeLost, ...)` includes the
        // `.pause` action, which drives `handleCommand(.pause)` in production) — not at a command
        // boundary, mid-track.
        var engine = WatchPlayerEngine(queue: ["t1"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        engine.updateElapsed(90.0)
        _ = engine.command(.pause)
        #expect(engine.elapsed == 90.0)

        // The user goes back to the watch and presses Play — the same `.play` command every resume
        // uses.
        let resumeDirectives = engine.command(.play, urlForTrack: { [self] in urlMap($0) })

        #expect(resumeDirectives == [.loadItem(urlMap("t1")!), .play])
        #expect(engine.elapsed == 90.0, "resuming must not restart the track from the beginning")
    }

    @Test func testUpdateElapsedIsIgnoredWithAnEmptyQueue() {
        var engine = WatchPlayerEngine()
        engine.updateElapsed(42.0)
        #expect(engine.elapsed == 0)
    }

    @Test func testUpdateElapsedClampsNegativeValues() {
        var engine = WatchPlayerEngine(queue: ["t1"])
        _ = engine.command(.play, urlForTrack: { [self] in urlMap($0) })
        engine.updateElapsed(-5.0)
        #expect(engine.elapsed == 0)
    }
}
