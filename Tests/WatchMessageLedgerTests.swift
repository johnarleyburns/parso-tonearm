import XCTest
@testable import TonearmWatchProtocol

/// C-05..C-07: duplicate delivery is idempotent, stale revisions do not roll state backward, and
/// out-of-order arrivals converge on the highest revision.
final class WatchMessageLedgerTests: XCTestCase {
    // MARK: - C-05 duplicates

    func testTheSameMessageIsAdmittedOnceNoMatterHowOftenItArrives() async {
        let ledger = WatchAppliedMessageLedger()
        let id = UUID()
        var admissions: [WatchAppliedMessageLedger.Admission] = []
        for _ in 0..<10 { admissions.append(await ledger.admit(id)) }
        XCTAssertEqual(admissions.first, .apply)
        XCTAssertEqual(Set(admissions.dropFirst()), [.duplicate])
        let count = await ledger.count
        XCTAssertEqual(count, 1)
    }

    func testDistinctMessagesAreAllAdmitted() async {
        let ledger = WatchAppliedMessageLedger()
        for _ in 0..<50 {
            let admission = await ledger.admit(UUID())
            XCTAssertEqual(admission, .apply)
        }
        let count = await ledger.count
        XCTAssertEqual(count, 50)
    }

    func testConcurrentDeliveriesOfOneMessageStillApplyExactlyOnce() async {
        // WatchConnectivity can deliver the same user-info twice on different queues.
        let ledger = WatchAppliedMessageLedger()
        let id = UUID()
        let applied = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<32 { group.addTask { await ledger.admit(id) == .apply } }
            var count = 0
            for await wasApplied in group where wasApplied { count += 1 }
            return count
        }
        XCTAssertEqual(applied, 1, "the actor is the whole reason this is safe")
    }

    func testTheLedgerIsBoundedAndEvictsOldestFirst() async {
        let ledger = WatchAppliedMessageLedger(capacity: 4)
        let ids = (0..<4).map { _ in UUID() }
        for id in ids { _ = await ledger.admit(id) }
        let filled = await ledger.count
        XCTAssertEqual(filled, 4)

        let newest = UUID()
        _ = await ledger.admit(newest)
        let bounded = await ledger.count
        XCTAssertEqual(bounded, 4, "capacity is a hard bound; the watch has little memory")
        let oldestEvicted = await ledger.contains(ids[0])
        XCTAssertFalse(oldestEvicted)
        let secondSurvives = await ledger.contains(ids[1])
        XCTAssertTrue(secondSurvives)
        let newestSurvives = await ledger.contains(newest)
        XCTAssertTrue(newestSurvives)
    }

    func testTheLedgerSurvivesARelaunchThroughItsPersistence() async {
        let persistence = WatchInMemoryLedgerPersistence()
        let id = UUID()
        let before = WatchAppliedMessageLedger(persistence: persistence)
        let first = await before.admit(id)
        XCTAssertEqual(first, .apply)

        // A watch that applied a delete, then relaunched, must not apply it again.
        let after = WatchAppliedMessageLedger(persistence: persistence)
        let replay = await after.admit(id)
        XCTAssertEqual(replay, .duplicate)
    }

    func testTheFileLedgerIsReadableBeforeTheSwiftDataStoreOpens() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let id = UUID()
        let before = WatchAppliedMessageLedger(persistence: WatchFileLedgerPersistence(url: url))
        let first = await before.admit(id)
        XCTAssertEqual(first, .apply)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let after = WatchAppliedMessageLedger(persistence: WatchFileLedgerPersistence(url: url))
        let replay = await after.admit(id)
        XCTAssertEqual(replay, .duplicate)
    }

    func testAnUnreadableLedgerFileStartsEmptyRatherThanCrashing() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try? Data("this is not json".utf8).write(to: url)

        let ledger = WatchAppliedMessageLedger(persistence: WatchFileLedgerPersistence(url: url))
        let count = await ledger.count
        XCTAssertEqual(count, 0)
        let admission = await ledger.admit(UUID())
        XCTAssertEqual(admission, .apply)
    }

    // MARK: - C-07 stale revisions

    func testAStaleRevisionIsAcknowledgedWithoutRollingStateBackward() {
        var gate = WatchRevisionGate()
        XCTAssertEqual(gate.evaluate(scope: .catalog, revision: 5), .apply)
        XCTAssertEqual(gate.evaluate(scope: .catalog, revision: 3), .staleIgnored)
        XCTAssertEqual(gate.lastApplied(.catalog), 5, "the older payload must not overwrite the newer")
        XCTAssertEqual(gate.evaluate(scope: .catalog, revision: 5), .staleIgnored,
                       "a repeat of the applied revision is not new information")
        XCTAssertEqual(gate.evaluate(scope: .catalog, revision: 6), .apply)
    }

    func testTheFirstRevisionOfAScopeAlwaysApplies() {
        // A watch restored from backup can meet a phone whose counter is already high.
        var gate = WatchRevisionGate()
        XCTAssertEqual(gate.evaluate(scope: .downloadRoots, revision: 9_001), .apply)
        XCTAssertEqual(gate.lastApplied(.downloadRoots), 9_001)
    }

    func testScopesAreIndependent() {
        var gate = WatchRevisionGate()
        XCTAssertEqual(gate.evaluate(scope: .playback, revision: 100), .apply)
        // A high playback revision must not suppress a legitimately lower download-root revision.
        for scope in WatchRevisionScope.allCases where scope != .playback {
            XCTAssertEqual(gate.evaluate(scope: scope, revision: 1), .apply, "\(scope) was suppressed")
        }
        XCTAssertEqual(gate.lastApplied(.playback), 100)
    }

    // MARK: - C-06 out of order

    func testOutOfOrderArrivalsConvergeOnTheHighestRevision() {
        // Same three payloads, six delivery orders, one outcome.
        for order in [[1, 2, 3], [1, 3, 2], [2, 1, 3], [2, 3, 1], [3, 1, 2], [3, 2, 1]] {
            var gate = WatchRevisionGate()
            var applied: [Int64] = []
            for revision in order.map(Int64.init) where gate.evaluate(scope: .catalog, revision: revision) == .apply {
                applied.append(revision)
            }
            XCTAssertEqual(gate.lastApplied(.catalog), 3, "order \(order) did not converge")
            XCTAssertEqual(applied, applied.sorted(),
                           "order \(order) applied a revision after a newer one")
            XCTAssertEqual(applied.last, 3)
        }
    }

    func testResetForcesAScopeToAcceptTheNextPayload() {
        // What a reconciliation after store recovery needs: the phone's current revision may be
        // lower than whatever this watch recorded before it lost its store.
        var gate = WatchRevisionGate()
        _ = gate.evaluate(scope: .catalog, revision: 40)
        gate.reset(.catalog)
        XCTAssertEqual(gate.evaluate(scope: .catalog, revision: 12), .apply)

        _ = gate.evaluate(scope: .playback, revision: 7)
        gate.resetAll()
        XCTAssertEqual(gate.lastApplied(.playback), 0)
        XCTAssertEqual(gate.lastApplied(.catalog), 0)
    }
}
