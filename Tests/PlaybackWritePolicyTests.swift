import XCTest
@testable import TonearmCore

final class PlaybackWritePolicyTests: XCTestCase {

    private func snap(trackIDs: [Int64] = [1],
                      currentIndex: Int = 0,
                      elapsed: Double = 10,
                      isPlaying: Bool = true) -> PlaybackStateSnapshot {
        PlaybackStateSnapshot(
            trackIDs: trackIDs, currentIndex: currentIndex,
            elapsed: elapsed, isPlaying: isPlaying, savedAt: Date())
    }

    // MARK: - G4: clear admitted only for userClear

    func testClearAdmittedOnlyForUserClear() {
        for reason: PlaybackWriteReason in [.tick, .transportEvent, .userSeek,
                                            .queueChange, .restoreCommit, .background] {
            XCTAssertFalse(PlaybackWritePolicy.admits(
                candidate: nil, existing: snap(), reason: reason),
                "clear must be rejected for \(reason)")
        }
        XCTAssertTrue(PlaybackWritePolicy.admits(
            candidate: nil, existing: snap(), reason: .userClear))
    }

    // MARK: - First write always admitted

    func testFirstWriteAlwaysAdmitted() {
        for reason: PlaybackWriteReason in [.tick, .transportEvent, .userSeek,
                                            .queueChange, .restoreCommit, .background] {
            XCTAssertTrue(PlaybackWritePolicy.admits(
                candidate: snap(), existing: nil, reason: reason),
                "first write must be admitted for \(reason)")
        }
    }

    // MARK: - G3: tick regression rejected

    func testTickNeverRegressesElapsed() {
        let existing = snap(elapsed: 50)
        XCTAssertFalse(PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 40), existing: existing, reason: .tick),
            "tick must not regress elapsed")
        XCTAssertFalse(PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 40), existing: existing, reason: .background),
            "background must not regress elapsed")
    }

    func testTickAdvanceIsAdmitted() {
        let existing = snap(elapsed: 50)
        XCTAssertTrue(PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 52), existing: existing, reason: .tick),
            "tick advance must be admitted")
    }

    func testTickSmallRegressionWithinToleranceIsAdmitted() {
        let existing = snap(elapsed: 50)
        // Regression of 0.5 s is within 1.0 s tolerance
        XCTAssertTrue(PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 49.5), existing: existing, reason: .tick),
            "tick regression ≤1 s must be admitted")
    }

    // MARK: - Explicit actions always admitted for regressions

    func testUserSeekRegressionIsAdmitted() {
        let existing = snap(elapsed: 100)
        XCTAssertTrue(PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 10), existing: existing, reason: .userSeek),
            "user seek back must be admitted")
    }

    func testTransportEventRegressionIsAdmitted() {
        let existing = snap(elapsed: 100)
        XCTAssertTrue(PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 10), existing: existing, reason: .transportEvent),
            "transport event must be admitted even on regression")
    }

    func testRestoreCommitRegressionIsAdmitted() {
        let existing = snap(elapsed: 0)  // transient tick
        XCTAssertTrue(PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 190), existing: existing, reason: .restoreCommit),
            "restore commit must be admitted")
    }

    // MARK: - Different queue/index always admitted

    func testDifferentTrackIDsAlwaysAdmitted() {
        let existing = snap(trackIDs: [1, 2])
        XCTAssertTrue(PlaybackWritePolicy.admits(
            candidate: snap(trackIDs: [3, 4]), existing: existing, reason: .tick),
            "different track IDs must be admitted")
    }

    func testDifferentCurrentIndexAlwaysAdmitted() {
        let existing = snap(trackIDs: [1, 2, 3], currentIndex: 0)
        XCTAssertTrue(PlaybackWritePolicy.admits(
            candidate: snap(trackIDs: [1, 2, 3], currentIndex: 1),
            existing: existing, reason: .tick),
            "different current index must be admitted")
    }
}
