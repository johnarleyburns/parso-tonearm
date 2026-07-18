import XCTest
@testable import TonearmCore

@MainActor
final class QueueRestorePlannerTests: XCTestCase {

    // MARK: - Full resolve

    func testFullResolveReturnsAllTracks() async throws {
        let saved = snapshot(ids: [1, 2, 3], currentIndex: 1, elapsed: 30)
        let optPlan = await QueueRestorePlanner.plan(
            saved: saved,
            resolveByID: { id in TrackRow.fake(trackId: id) },
            resolveBySyncID: { _ in nil })
        let plan = try XCTUnwrap(optPlan)
        XCTAssertEqual(plan.rows.count, 3)
        XCTAssertEqual(plan.startIndex, 1)
        XCTAssertEqual(plan.seekTo, 30, accuracy: 0.01)
    }

    // MARK: - Partial resolve with index remap

    func testPartialResolveRemapsIndex() async throws {
        let saved = snapshot(ids: [1, 2, 3], currentIndex: 1, elapsed: 20)
        let optPlan = await QueueRestorePlanner.plan(
            saved: saved,
            resolveByID: { id in
                id == 2 ? nil : TrackRow.fake(trackId: id)
            },
            resolveBySyncID: { _ in nil })
        let plan = try XCTUnwrap(optPlan)
        XCTAssertEqual(plan.rows.count, 2)
        XCTAssertEqual(plan.rows.map(\.id), [1, 3])
        XCTAssertEqual(plan.startIndex, 0, "startIndex stays 0 when current track is unresolved")
        // Current track (id=2) missing → Loss #5: seekTo must be 0
        XCTAssertEqual(plan.seekTo, 0, accuracy: 0.01)
    }

    // MARK: - Current-track-missing → seekTo 0 (Loss #5)

    func testMissingCurrentTrackZeroesSeek() async throws {
        let saved = snapshot(ids: [999, 2, 3], currentIndex: 0, elapsed: 100)
        let optPlan = await QueueRestorePlanner.plan(
            saved: saved,
            resolveByID: { id in
                id == 999 ? nil : TrackRow.fake(trackId: id)
            },
            resolveBySyncID: { _ in nil })
        let plan = try XCTUnwrap(optPlan)
        XCTAssertEqual(plan.rows.count, 2)
        XCTAssertEqual(plan.startIndex, 0)
        XCTAssertEqual(plan.seekTo, 0, accuracy: 0.01,
            "elapsed must be 0 when saved current track is missing")
    }

    // MARK: - rowid miss + syncID hit (reinstall shape)

    func testRowIDMissFallsBackToSyncID() async throws {
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
        let plan = try XCTUnwrap(optPlan)
        XCTAssertEqual(plan.rows.count, 1)
        XCTAssertEqual(plan.rows[0].id, 999)
        XCTAssertEqual(plan.seekTo, 40, accuracy: 0.01)
    }

    // MARK: - Empty resolve → nil plan

    func testNoTracksResolvedReturnsNil() async {
        let saved = snapshot(ids: [1, 2], currentIndex: 0, elapsed: 5)
        let plan = await QueueRestorePlanner.plan(
            saved: saved,
            resolveByID: { _ in nil },
            resolveBySyncID: { _ in nil })
        XCTAssertNil(plan)
    }

    // MARK: - End-of-track clamp

    func testEndOfTrackClampedToDurationMinusHalfSecond() async throws {
        let row = TrackRow.fake(trackId: 1, duration: 240)
        let saved = snapshot(ids: [1], currentIndex: 0, elapsed: 239.8)
        let optPlan = await QueueRestorePlanner.plan(
            saved: saved,
            resolveByID: { _ in row },
            resolveBySyncID: { _ in nil })
        let plan = try XCTUnwrap(optPlan)
        XCTAssertEqual(plan.seekTo, 239.5, accuracy: 0.01,
            "near-end-of-track elapsed must be clamped")
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
