import XCTest
@testable import TonearmCore

/// C7 — conflict-resolution rules: last-writer-wins for scalar records, additive
/// merge for play history, and deletion tombstones. All pure (no CloudKit).
final class SyncMergeTests: XCTestCase {

    func testLastWriterWinsPrefersNewerRemote() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(SyncMerge.remoteWins(localModified: old, remoteModified: new))
        XCTAssertEqual(SyncMerge.winner(local: "L", localModified: old,
                                        remote: "R", remoteModified: new), "R")
    }

    func testLastWriterWinsKeepsNewerLocal() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        XCTAssertFalse(SyncMerge.remoteWins(localModified: new, remoteModified: old))
        XCTAssertEqual(SyncMerge.winner(local: "L", localModified: new,
                                        remote: "R", remoteModified: old), "L")
    }

    func testMissingLocalDateLetsRemoteWin() {
        XCTAssertTrue(SyncMerge.remoteWins(localModified: nil,
                                           remoteModified: Date(timeIntervalSince1970: 1)))
    }

    func testPlayHistoryIsAdditiveUnionBySyncID() {
        let shared = PlayEvent(id: 1, trackId: 1, playedAt: Date(timeIntervalSince1970: 50), syncID: "A")
        let localOnly = PlayEvent(id: 2, trackId: 1, playedAt: Date(timeIntervalSince1970: 10), syncID: "B")
        let remoteOnly = PlayEvent(id: nil, trackId: 1, playedAt: Date(timeIntervalSince1970: 90), syncID: "C")

        let merged = SyncMerge.mergePlayHistory(local: [shared, localOnly],
                                                remote: [shared, remoteOnly])
        XCTAssertEqual(merged.count, 3, "union should keep every distinct event")
        XCTAssertEqual(merged.map { $0.syncID }, ["B", "A", "C"], "ordered by playedAt")
    }

    func testPlayHistoryDedupesSameSyncID() {
        let a = PlayEvent(id: 1, trackId: 1, playedAt: Date(timeIntervalSince1970: 1), syncID: "X")
        let merged = SyncMerge.mergePlayHistory(local: [a], remote: [a])
        XCTAssertEqual(merged.count, 1)
    }

    func testDeletionTombstonesRemoveLocal() {
        let result = SyncMerge.applyDeletions(local: ["A", "B", "C"], deleted: ["B"])
        XCTAssertEqual(result, ["A", "C"])
    }
}
