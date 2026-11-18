import Testing
import CloudKit
@testable import TonearmCore

@MainActor @Suite struct PlaybackCloudMirrorTests {

    // MARK: - Record round-trip

    @Test func testPlaybackStateRecordRoundTrip() throws {
        let snap = PlaybackStateSnapshot(
            trackIDs: [1, 2, 3],
            trackSyncIDs: ["s1", "s2", nil],
            currentIndex: 1,
            elapsed: 42.5,
            isPlaying: true,
            savedAt: Date(timeIntervalSince1970: 1_000_000))

        let zoneID = CKRecordZone.ID(zoneName: "test", ownerName: CKCurrentUserDefaultName)
        let record = RecordMapping.record(from: snap, zoneID: zoneID)

        let restored = try #require(RecordMapping.playbackState(from: record))
        #expect(restored.trackIDs == [1, 2, 3])
        #expect(restored.trackSyncIDs == ["s1", "s2", nil])
        #expect(restored.currentIndex == 1)
        #expect(abs((restored.elapsed) - (42.5)) <= 0.01)
        #expect(restored.isPlaying)
    }

    // MARK: - Merge: latest savedAt wins

    @Test func testLatestSavedAtWins() {
        let local = PlaybackStateSnapshot(
            trackIDs: [1], currentIndex: 0, elapsed: 30,
            isPlaying: true, savedAt: Date(timeIntervalSince1970: 100))
        let remote = PlaybackStateSnapshot(
            trackIDs: [2], currentIndex: 0, elapsed: 60,
            isPlaying: false, savedAt: Date(timeIntervalSince1970: 200))

        let winner = SyncMerge.winner(
            local: local, localModified: local.savedAt,
            remote: remote, remoteModified: remote.savedAt)
        #expect(winner.trackIDs == [2], "remote wins (newer savedAt)")
    }

    @Test func testTieGoesToLocal() {
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
        #expect(winner.trackIDs == [2], "tie → remote wins (≥ comparison)")
    }

    // MARK: - 30 s throttle

    @Test func testCloudPushThrottleInterval() {
        #expect(PlaybackPositionPersistor.cloudPushInterval == 30, "cloud push must throttle to 30 s")
    }
}
