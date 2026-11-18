import Testing
@testable import TonearmCore

@Suite struct PlaybackWritePolicyTests {

    private func snap(trackIDs: [Int64] = [1],
                      currentIndex: Int = 0,
                      elapsed: Double = 10,
                      isPlaying: Bool = true) -> PlaybackStateSnapshot {
        PlaybackStateSnapshot(
            trackIDs: trackIDs, currentIndex: currentIndex,
            elapsed: elapsed, isPlaying: isPlaying, savedAt: Date())
    }

    // MARK: - G4: clear admitted only for userClear

    @Test func testClearAdmittedOnlyForUserClear() {
        for reason: PlaybackWriteReason in [.tick, .transportEvent, .userSeek,
                                            .queueChange, .restoreCommit, .background] {
            #expect(!PlaybackWritePolicy.admits(
                candidate: nil, existing: snap(), reason: reason), "clear must be rejected for \(reason)")
        }
        #expect(PlaybackWritePolicy.admits(
            candidate: nil, existing: snap(), reason: .userClear))
    }

    // MARK: - First write always admitted

    @Test func testFirstWriteAlwaysAdmitted() {
        for reason: PlaybackWriteReason in [.tick, .transportEvent, .userSeek,
                                            .queueChange, .restoreCommit, .background] {
            #expect(PlaybackWritePolicy.admits(
                candidate: snap(), existing: nil, reason: reason), "first write must be admitted for \(reason)")
        }
    }

    // MARK: - G3: tick regression rejected

    @Test func testTickNeverRegressesElapsed() {
        let existing = snap(elapsed: 50)
        #expect(!PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 40), existing: existing, reason: .tick), "tick must not regress elapsed")
        #expect(!PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 40), existing: existing, reason: .background), "background must not regress elapsed")
    }

    @Test func testTickAdvanceIsAdmitted() {
        let existing = snap(elapsed: 50)
        #expect(PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 52), existing: existing, reason: .tick), "tick advance must be admitted")
    }

    @Test func testTickSmallRegressionWithinToleranceIsAdmitted() {
        let existing = snap(elapsed: 50)
        // Regression of 0.5 s is within 1.0 s tolerance
        #expect(PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 49.5), existing: existing, reason: .tick), "tick regression ≤1 s must be admitted")
    }

    // MARK: - Explicit actions always admitted for regressions

    @Test func testUserSeekRegressionIsAdmitted() {
        let existing = snap(elapsed: 100)
        #expect(PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 10), existing: existing, reason: .userSeek), "user seek back must be admitted")
    }

    @Test func testTransportEventRegressionIsAdmitted() {
        let existing = snap(elapsed: 100)
        #expect(PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 10), existing: existing, reason: .transportEvent), "transport event must be admitted even on regression")
    }

    @Test func testRestoreCommitRegressionIsAdmitted() {
        let existing = snap(elapsed: 0)  // transient tick
        #expect(PlaybackWritePolicy.admits(
            candidate: snap(elapsed: 190), existing: existing, reason: .restoreCommit), "restore commit must be admitted")
    }

    // MARK: - Different queue/index always admitted

    @Test func testDifferentTrackIDsAlwaysAdmitted() {
        let existing = snap(trackIDs: [1, 2])
        #expect(PlaybackWritePolicy.admits(
            candidate: snap(trackIDs: [3, 4]), existing: existing, reason: .tick), "different track IDs must be admitted")
    }

    @Test func testDifferentCurrentIndexAlwaysAdmitted() {
        let existing = snap(trackIDs: [1, 2, 3], currentIndex: 0)
        #expect(PlaybackWritePolicy.admits(
            candidate: snap(trackIDs: [1, 2, 3], currentIndex: 1),
            existing: existing, reason: .tick), "different current index must be admitted")
    }
}
