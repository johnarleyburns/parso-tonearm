import XCTest
import TonearmWatchProtocol
@testable import TonearmWatchCore

/// Phase 9c — the pure remote-playback prediction the watch draws the iPhone target from (§7.1).
final class WatchRemotePlaybackStateTests: XCTestCase {

    private func snapshot(revision: Int64 = 1, playing: Bool = true, rate: Double = 1,
                          elapsed: Double = 10, duration: Double? = 200,
                          anchor: Date) -> WatchPhonePlaybackSnapshot {
        WatchPhonePlaybackSnapshot(
            revision: revision, source: .localLibrary, isPlaying: playing, rate: rate,
            currentItem: WatchTrackSummary(trackID: WatchTrackID("t1"), title: "Track",
                                           durationSeconds: duration),
            queueWindow: [], queueIndex: 0, queueCount: 1,
            elapsedSeconds: elapsed, elapsedAnchorDate: anchor)
    }

    func testPredictedElapsedAdvancesWithWallClockAtRate() {
        let anchor = Date()
        let state = WatchRemotePlaybackState(snapshot: snapshot(anchor: anchor), receivedAt: anchor)
        XCTAssertEqual(state.predictedElapsed(at: anchor), 10, accuracy: 0.001)
        XCTAssertEqual(state.predictedElapsed(at: anchor.addingTimeInterval(30)), 40, accuracy: 0.001)
    }

    func testPredictedElapsedIsFrozenWhenPaused() {
        let anchor = Date()
        let state = WatchRemotePlaybackState(
            snapshot: snapshot(playing: false, rate: 0, anchor: anchor), receivedAt: anchor)
        XCTAssertEqual(state.predictedElapsed(at: anchor.addingTimeInterval(60)), 10, accuracy: 0.001)
    }

    func testPredictedElapsedIsClampedToDuration() throws {
        let anchor = Date()
        let state = WatchRemotePlaybackState(
            snapshot: snapshot(elapsed: 190, duration: 200, anchor: anchor), receivedAt: anchor)
        XCTAssertEqual(state.predictedElapsed(at: anchor.addingTimeInterval(60)), 200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(state.predictedRemaining(at: anchor.addingTimeInterval(60))),
                       0, accuracy: 0.001)
    }

    func testStalenessTracksReceivedAt() {
        let received = Date()
        let state = WatchRemotePlaybackState(snapshot: snapshot(anchor: received), receivedAt: received)
        XCTAssertFalse(state.isStale(at: received.addingTimeInterval(5)))
        XCTAssertTrue(state.isStale(at: received.addingTimeInterval(20)))
    }

    func testApplyingNewerRevisionReplacesState() throws {
        let t0 = Date()
        let state = WatchRemotePlaybackState(snapshot: snapshot(revision: 3, anchor: t0), receivedAt: t0)
        let next = try XCTUnwrap(state.applying(snapshot(revision: 4, elapsed: 99, anchor: t0), at: t0))
        XCTAssertEqual(next.snapshot.elapsedSeconds, 99)
    }

    func testApplyingOlderRevisionIsRejected() {
        let t0 = Date()
        let state = WatchRemotePlaybackState(snapshot: snapshot(revision: 5, anchor: t0), receivedAt: t0)
        XCTAssertNil(state.applying(snapshot(revision: 4, anchor: t0), at: t0))
    }
}
