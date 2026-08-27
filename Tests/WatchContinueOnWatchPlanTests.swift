import XCTest
import TonearmWatchProtocol
@testable import TonearmWatchCore

/// Phase 9d — the pure §7.5 "Continue on Apple Watch" projection.
final class WatchContinueOnWatchPlanTests: XCTestCase {

    private func item(_ id: String, duration: Double? = 200) -> WatchTrackSummary {
        WatchTrackSummary(trackID: WatchTrackID(id), title: id, durationSeconds: duration)
    }

    private func snapshot(current: String, window: [String], elapsed: Double = 30,
                          anchor: Date) -> WatchPhonePlaybackSnapshot {
        let summaries = window.map { item($0) }
        return WatchPhonePlaybackSnapshot(
            revision: 1, source: .localLibrary, isPlaying: true, rate: 1,
            currentItem: item(current),
            queueWindow: summaries, queueWindowStartIndex: 0,
            queueIndex: window.firstIndex(of: current) ?? 0, queueCount: window.count,
            elapsedSeconds: elapsed, elapsedAnchorDate: anchor)
    }

    func testNoOfferWhenCurrentTrackIsNotDownloaded() {
        let t = Date()
        let snap = snapshot(current: "b", window: ["a", "b", "c"], anchor: t)
        XCTAssertNil(WatchContinueOnWatchPlan.make(
            from: snap, locallyAvailable: [WatchTrackID("a"), WatchTrackID("c")], now: t))
    }

    func testOffersDownloadedMembersInOrderWithClampedAnchor() {
        let t = Date()
        let snap = snapshot(current: "b", window: ["a", "b", "c", "d"], elapsed: 30, anchor: t)
        let plan = WatchContinueOnWatchPlan.make(
            from: snap,
            locallyAvailable: [WatchTrackID("b"), WatchTrackID("d")],
            now: t.addingTimeInterval(10))
        XCTAssertEqual(plan?.trackIDs, [WatchTrackID("b"), WatchTrackID("d")])
        XCTAssertEqual(plan?.startIndex, 0)
        XCTAssertEqual(plan?.elapsedAnchor ?? -1, 40, accuracy: 0.001)  // 30 + 10s wall clock
    }

    func testAnchorClampsToDuration() {
        let t = Date()
        var snap = snapshot(current: "a", window: ["a"], elapsed: 195, anchor: t)
        snap.currentItem = item("a", duration: 200)
        let plan = WatchContinueOnWatchPlan.make(
            from: snap, locallyAvailable: [WatchTrackID("a")], now: t.addingTimeInterval(60))
        XCTAssertEqual(plan?.elapsedAnchor ?? -1, 200, accuracy: 0.001)
    }

    func testEmptyWindowStillContinuesTheCurrentTrack() {
        let t = Date()
        let snap = snapshot(current: "a", window: [], anchor: t)
        let plan = WatchContinueOnWatchPlan.make(
            from: snap, locallyAvailable: [WatchTrackID("a")], now: t)
        XCTAssertEqual(plan?.trackIDs, [WatchTrackID("a")])
        XCTAssertEqual(plan?.startIndex, 0)
    }

    func testNoOfferWhenNothingIsPlaying() {
        let snap = WatchPhonePlaybackSnapshot(revision: 1)
        XCTAssertNil(WatchContinueOnWatchPlan.make(from: snap, locallyAvailable: []))
    }

    func testStartIndexPointsAtTheCurrentTrackAmongSurvivors() {
        let t = Date()
        let snap = snapshot(current: "c", window: ["a", "b", "c", "d"], anchor: t)
        let plan = WatchContinueOnWatchPlan.make(
            from: snap,
            locallyAvailable: [WatchTrackID("a"), WatchTrackID("c"), WatchTrackID("d")], now: t)
        XCTAssertEqual(plan?.trackIDs, [WatchTrackID("a"), WatchTrackID("c"), WatchTrackID("d")])
        XCTAssertEqual(plan?.startIndex, 1)
    }
}
