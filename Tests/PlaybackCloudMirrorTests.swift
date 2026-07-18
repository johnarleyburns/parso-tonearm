import XCTest
import CloudKit
@testable import TonearmCore

final class PlaybackCloudMirrorTests: XCTestCase {

    // MARK: - Record round-trip

    func testPlaybackStateRecordRoundTrip() throws {
        let snap = PlaybackStateSnapshot(
            trackIDs: [1, 2, 3],
            trackSyncIDs: ["s1", "s2", nil],
            currentIndex: 1,
            elapsed: 42.5,
            isPlaying: true,
            savedAt: Date(timeIntervalSince1970: 1_000_000))

        let zoneID = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let record = RecordMapping.record(from: snap, zoneID: zoneID)

        let restored = try XCTUnwrap(RecordMapping.playbackState(from: record))
        XCTAssertEqual(restored.trackIDs, [1, 2, 3])
        XCTAssertEqual(restored.trackSyncIDs, ["s1", "s2", nil])
        XCTAssertEqual(restored.currentIndex, 1)
        XCTAssertEqual(restored.elapsed, 42.5, accuracy: 0.01)
        XCTAssertTrue(restored.isPlaying)
    }

    // MARK: - Merge: latest savedAt wins

    func testLatestSavedAtWins() {
        let local = PlaybackStateSnapshot(
            trackIDs: [1], currentIndex: 0, elapsed: 30,
            isPlaying: true, savedAt: Date(timeIntervalSince1970: 100))
        let remote = PlaybackStateSnapshot(
            trackIDs: [2], currentIndex: 0, elapsed: 60,
            isPlaying: false, savedAt: Date(timeIntervalSince1970: 200))

        let winner = SyncMerge.winner(
            local: local, localModified: local.savedAt,
            remote: remote, remoteModified: remote.savedAt)
        XCTAssertEqual(winner.trackIDs, [2], "remote wins (newer savedAt)")
    }

    func testTieGoesToLocal() {
        let date = Date(timeIntervalSince1970: 100)
        let local = PlaybackStateSnapshot(
            trackIDs: [1], currentIndex: 0, elapsed: 30,
            isPlaying: true, savedAt: date)
        let remote = PlaybackStateSnapshot(
            trackIDs: [2], currentIndex: 0, elapsed: 60,
            isPlaying: false, savedAt: date)

        let winner = SyncMerge.winner(
            local: local, localModified: local.savedAt,
            remote: remote, remoteModified: remote.savedAt)
        XCTAssertEqual(winner.trackIDs, [2],
            "tie → remote wins (≥ comparison)")
    }

    // MARK: - 30 s throttle

    func testCloudPushThrottleInterval() {
        XCTAssertEqual(PlaybackPositionPersistor.cloudPushInterval, 30,
            "cloud push must throttle to 30 s")
    }
}
