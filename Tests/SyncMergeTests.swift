import Testing
@testable import TonearmCore

/// C7 — conflict-resolution rules: last-writer-wins for scalar records, additive
/// merge for play history, and deletion tombstones. All pure (no CloudKit).
@Suite struct SyncMergeTests {

    @Test func testLastWriterWinsPrefersNewerRemote() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        #expect(SyncMerge.remoteWins(localModified: old, remoteModified: new))
        #expect(SyncMerge.winner(local: "L", localModified: old,
                                        remote: "R", remoteModified: new) == "R")
    }

    @Test func testLastWriterWinsKeepsNewerLocal() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        #expect(!SyncMerge.remoteWins(localModified: new, remoteModified: old))
        #expect(SyncMerge.winner(local: "L", localModified: new,
                                        remote: "R", remoteModified: old) == "L")
    }

    @Test func testMissingLocalDateLetsRemoteWin() {
        #expect(SyncMerge.remoteWins(localModified: nil,
                                           remoteModified: Date(timeIntervalSince1970: 1)))
    }

    @Test func testPlayHistoryIsAdditiveUnionBySyncID() {
        let shared = PlayEvent(id: 1, trackId: 1, playedAt: Date(timeIntervalSince1970: 50), syncID: "A")
        let localOnly = PlayEvent(id: 2, trackId: 1, playedAt: Date(timeIntervalSince1970: 10), syncID: "B")
        let remoteOnly = PlayEvent(id: nil, trackId: 1, playedAt: Date(timeIntervalSince1970: 90), syncID: "C")

        let merged = SyncMerge.mergePlayHistory(local: [shared, localOnly],
                                                remote: [shared, remoteOnly])
        #expect(merged.count == 3, "union should keep every distinct event")
        #expect(merged.map { $0.syncID } == ["B", "A", "C"], "ordered by playedAt")
    }

    @Test func testPlayHistoryDedupesSameSyncID() {
        let a = PlayEvent(id: 1, trackId: 1, playedAt: Date(timeIntervalSince1970: 1), syncID: "X")
        let merged = SyncMerge.mergePlayHistory(local: [a], remote: [a])
        #expect(merged.count == 1)
    }

    @Test func testDeletionTombstonesRemoveLocal() {
        let result = SyncMerge.applyDeletions(local: ["A", "B", "C"], deleted: ["B"])
        #expect(result == ["A", "C"])
    }
}
