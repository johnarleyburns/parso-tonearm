import Foundation
import Testing
@testable import TonearmWatchProtocol

/// C-05..C-07: duplicate delivery is idempotent, stale revisions do not roll state backward, and
/// out-of-order arrivals converge on the highest revision.
@Suite struct WatchMessageLedgerTests {
    // MARK: - C-05 duplicates

    @Test func testTheSameMessageIsAdmittedOnceNoMatterHowOftenItArrives() async {
        let ledger = WatchAppliedMessageLedger()
        let id = UUID()
        var admissions: [WatchAppliedMessageLedger.Admission] = []
        for _ in 0..<10 { admissions.append(await ledger.admit(id)) }
        #expect(admissions.first == .apply)
        #expect(Set(admissions.dropFirst()) == [.duplicate])
        let count = await ledger.count
        #expect(count == 1)
    }

    @Test func testDistinctMessagesAreAllAdmitted() async {
        let ledger = WatchAppliedMessageLedger()
        for _ in 0..<50 {
            let admission = await ledger.admit(UUID())
            #expect(admission == .apply)
        }
        let count = await ledger.count
        #expect(count == 50)
    }

    @Test func testConcurrentDeliveriesOfOneMessageStillApplyExactlyOnce() async {
        // WatchConnectivity can deliver the same user-info twice on different queues.
        let ledger = WatchAppliedMessageLedger()
        let id = UUID()
        let applied = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { await ledger.admit(id) == .apply } }
            var count = 0
            for await wasApplied in group where wasApplied { count += 1 }
            return count
        }
        #expect(applied == 1, "the actor is the whole reason this is safe")
    }

    @Test func testTheLedgerIsBoundedAndEvictsOldestFirst() async {
        let ledger = WatchAppliedMessageLedger(capacity: 4)
        let ids = (0..<4).map { _ in UUID() }
        for id in ids { _ = await ledger.admit(id) }
        let filled = await ledger.count
        #expect(filled == 4)

        let newest = UUID()
        _ = await ledger.admit(newest)
        let bounded = await ledger.count
        #expect(bounded == 4, "capacity is a hard bound; the watch has little memory")
        let oldestEvicted = await ledger.contains(ids[0])
        #expect(!oldestEvicted)
        let secondSurvives = await ledger.contains(ids[1])
        #expect(secondSurvives)
        let newestSurvives = await ledger.contains(newest)
        #expect(newestSurvives)
    }

    @Test func testTheLedgerSurvivesARelaunchThroughItsPersistence() async {
        let persistence = WatchInMemoryLedgerPersistence()
        let id = UUID()
        let before = WatchAppliedMessageLedger(persistence: persistence)
        let first = await before.admit(id)
        #expect(first == .apply)

        // A watch that applied a delete, then relaunched, must not apply it again.
        let after = WatchAppliedMessageLedger(persistence: persistence)
        let replay = await after.admit(id)
        #expect(replay == .duplicate)
    }

    @Test func testTheFileLedgerIsReadableBeforeTheSwiftDataStoreOpens() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let id = UUID()
        let before = WatchAppliedMessageLedger(persistence: WatchFileLedgerPersistence(url: url))
        let first = await before.admit(id)
        #expect(first == .apply)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let after = WatchAppliedMessageLedger(persistence: WatchFileLedgerPersistence(url: url))
        let replay = await after.admit(id)
        #expect(replay == .duplicate)
    }

    @Test func testAnUnreadableLedgerFileStartsEmptyRatherThanCrashing() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("this is not json".utf8).write(to: url)

        let ledger = WatchAppliedMessageLedger(persistence: WatchFileLedgerPersistence(url: url))
        let count = await ledger.count
        #expect(count == 0)
        let admission = await ledger.admit(UUID())
        #expect(admission == .apply)
    }

    // MARK: - C-07 stale revisions

    @Test func testAStaleRevisionIsAcknowledgedWithoutRollingStateBackward() {
        var gate = WatchRevisionGate()
        #expect(gate.evaluate(scope: .catalog, revision: 5) == .apply)
        #expect(gate.evaluate(scope: .catalog, revision: 3) == .staleIgnored)
        #expect(gate.lastApplied(.catalog) == 5, "the older payload must not overwrite the newer")
        #expect(gate.evaluate(scope: .catalog, revision: 5) == .staleIgnored,
                       "a repeat of the applied revision is not new information")
        #expect(gate.evaluate(scope: .catalog, revision: 6) == .apply)
    }

    @Test func testTheFirstRevisionOfAScopeAlwaysApplies() {
        // A watch restored from backup can meet a phone whose counter is already high.
        var gate = WatchRevisionGate()
        #expect(gate.evaluate(scope: .downloadRoots, revision: 9_001) == .apply)
        #expect(gate.lastApplied(.downloadRoots) == 9_001)
    }

    @Test func testScopesAreIndependent() {
        var gate = WatchRevisionGate()
        #expect(gate.evaluate(scope: .playback, revision: 100) == .apply)
        // A high playback revision must not suppress a legitimately lower download-root revision.
        for scope in WatchRevisionScope.allCases where scope != .playback {
            #expect(gate.evaluate(scope: scope, revision: 1) == .apply, "\(scope) was suppressed")
        }
        #expect(gate.lastApplied(.playback) == 100)
    }

    // MARK: - C-06 out of order

    @Test func testOutOfOrderArrivalsConvergeOnTheHighestRevision() {
        // Same three payloads, six delivery orders, one outcome.
        for order in [[1, 2, 3], [1, 3, 2], [2, 1, 3], [2, 3, 1], [3, 1, 2], [3, 2, 1]] {
            var gate = WatchRevisionGate()
            var applied: [Int64] = []
            for revision in order.map(Int64.init) where gate.evaluate(scope: .catalog, revision: revision) == .apply {
                applied.append(revision)
            }
            #expect(gate.lastApplied(.catalog) == 3, "order \(order) did not converge")
            #expect(applied == applied.sorted(),
                           "order \(order) applied a revision after a newer one")
            #expect(applied.last == 3)
        }
    }

    @Test func testResetForcesAScopeToAcceptTheNextPayload() {
        // What a reconciliation after store recovery needs: the phone's current revision may be
        // lower than whatever this watch recorded before it lost its store.
        var gate = WatchRevisionGate()
        _ = gate.evaluate(scope: .catalog, revision: 40)
        gate.reset(.catalog)
        #expect(gate.evaluate(scope: .catalog, revision: 12) == .apply)

        _ = gate.evaluate(scope: .playback, revision: 7)
        gate.resetAll()
        #expect(gate.lastApplied(.playback) == 0)
        #expect(gate.lastApplied(.catalog) == 0)
    }
}
