import Foundation
import Testing
@testable import TonearmCore

@MainActor
@Suite struct QueueRestorePlannerTests {

    // MARK: - Full resolve

    @Test func testFullResolveReturnsAllTracks() async throws {
        let saved = snapshot(ids: [1, 2, 3], currentIndex: 1, elapsed: 30)
        let optPlan = await QueueRestorePlanner.plan(
            saved: saved,
            resolveByID: { id in TrackRow.fake(trackId: id) },
            resolveBySyncID: { _ in nil })
        let plan = try #require(optPlan)
        #expect(plan.rows.count == 3)
        #expect(plan.startIndex == 1)
        #expect(abs((plan.seekTo) - (30)) <= 0.01)
    }

    // MARK: - Partial resolve with index remap

    @Test func testPartialResolveRemapsIndex() async throws {
        let saved = snapshot(ids: [1, 2, 3], currentIndex: 1, elapsed: 20)
        let optPlan = await QueueRestorePlanner.plan(
            saved: saved,
            resolveByID: { id in
                id == 2 ? nil : TrackRow.fake(trackId: id)
            },
            resolveBySyncID: { _ in nil })
        let plan = try #require(optPlan)
        #expect(plan.rows.count == 2)
        #expect(plan.rows.map(\.id) == [1, 3])
        #expect(plan.startIndex == 0, "startIndex stays 0 when current track is unresolved")
        // Current track (id=2) missing → Loss #5: seekTo must be 0
        #expect(abs((plan.seekTo) - (0)) <= 0.01)
    }

    // MARK: - Current-track-missing → seekTo 0 (Loss #5)

    @Test func testMissingCurrentTrackZeroesSeek() async throws {
        let saved = snapshot(ids: [999, 2, 3], currentIndex: 0, elapsed: 100)
        let optPlan = await QueueRestorePlanner.plan(
            saved: saved,
            resolveByID: { id in
                id == 999 ? nil : TrackRow.fake(trackId: id)
            },
            resolveBySyncID: { _ in nil })
        let plan = try #require(optPlan)
        #expect(plan.rows.count == 2)
        #expect(plan.startIndex == 0)
        #expect(abs((plan.seekTo) - (0)) <= 0.01, "elapsed must be 0 when saved current track is missing")
    }

    // MARK: - rowid miss + syncID hit (reinstall shape)

    @Test func testRowIDMissFallsBackToSyncID() async throws {
        let saved = PlaybackStateSnapshot(
            trackIDs: [1],
            trackSyncIDs: ["sync-aaa"],
            currentIndex: 0,
            elapsed: 40,
            isPlaying: false,
            savedAt: Date())
        let optPlan = await QueueRestorePlanner.plan(
            saved: saved,
            resolveByID: { _ in nil },
            resolveBySyncID: { syncID in
                syncID == "sync-aaa" ? TrackRow.fake(trackId: 999) : nil
            })
        let plan = try #require(optPlan)
        #expect(plan.rows.count == 1)
        #expect(plan.rows[0].id == 999)
        #expect(abs((plan.seekTo) - (40)) <= 0.01)
    }

    // MARK: - Empty resolve → nil plan

    @Test func testNoTracksResolvedReturnsNil() async {
        let saved = snapshot(ids: [1, 2], currentIndex: 0, elapsed: 5)
        let plan = await QueueRestorePlanner.plan(
            saved: saved,
            resolveByID: { _ in nil },
            resolveBySyncID: { _ in nil })
        #expect(plan == nil)
    }

    // MARK: - End-of-track clamp

    @Test func testEndOfTrackClampedToDurationMinusHalfSecond() async throws {
        let row = TrackRow.fake(trackId: 1, duration: 240)
        let saved = snapshot(ids: [1], currentIndex: 0, elapsed: 239.8)
        let optPlan = await QueueRestorePlanner.plan(
            saved: saved,
            resolveByID: { _ in row },
            resolveBySyncID: { _ in nil })
        let plan = try #require(optPlan)
        #expect(abs((plan.seekTo) - (239.5)) <= 0.01, "near-end-of-track elapsed must be clamped")
    }

    // MARK: - Helpers

    private func snapshot(ids: [Int64], currentIndex: Int, elapsed: Double) -> PlaybackStateSnapshot {
        PlaybackStateSnapshot(
            trackIDs: ids,
            currentIndex: currentIndex,
            elapsed: elapsed,
            isPlaying: false,
            savedAt: Date())
    }
}

private extension TrackRow {
    static func fake(trackId: Int64, duration: Double = 200) -> TrackRow {
        TrackRow(
            track: Track(id: trackId, albumId: nil, sourceId: 1,
                         title: "T\(trackId)", trackNo: 1, discNo: nil,
                         durationSec: duration, codec: "MP3", sampleRate: nil,
                         bitDepthOrBitrate: nil, sortKey: "T\(trackId)"),
            album: nil, source: nil, asset: nil)
    }
}
