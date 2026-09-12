import GRDB
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// C03 import-side durability fixtures (IMPLEMENT_CLAP_PLAN.md §4/§5):
/// `discovery_import_job`/`discovery_import_item` persistence, resumable
/// cursors and idempotent replay via `unique(jobId, identity)`. This was the
/// one named C03 gap sessions 1-3 explicitly left undone ("the record types
/// already exist ... but nothing reads/writes them yet").
final class ImportJobRepositoryTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        var config = Configuration()
        config.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: config)
        try Schema.migrator().migrate(queue)
        return queue
    }

    @discardableResult
    private func insertSource(_ queue: DatabaseQueue) async throws -> Int64 {
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO source (kind, title, addedAt, followUpdates, memberCapHit,
                                        localIsFolder)
                    VALUES ('dropbox', 'Dropbox', ?, 0, 0, 0)
                    """, arguments: [Date()])
            return db.lastInsertedRowID
        }
    }

    /// `discovery_import_item.resultingTrackId` has a real FK to `track`
    /// (plan §4), so any test recording an "imported" outcome needs a real
    /// track row to point at.
    @discardableResult
    private func insertTrack(_ queue: DatabaseQueue, sourceId: Int64, title: String = "Song") async throws -> Int64 {
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO track (sourceId, title, sortKey) VALUES (?, ?, ?)",
                arguments: [sourceId, title, title.lowercased()])
            return db.lastInsertedRowID
        }
    }

    func testStartOrResumeCreatesNewJobWhenNoneExists() async throws {
        let queue = try makeQueue()
        let sourceId = try await insertSource(queue)
        let repo = ImportJobRepository(writer: queue)

        let job = try await repo.startOrResume(sourceId: sourceId, sourceKind: "dropbox")
        XCTAssertEqual(job.state, .queued)
        XCTAssertEqual(job.sourceId, sourceId)
        XCTAssertEqual(job.discoveredCount, 0)
    }

    func testStartOrResumeReusesExistingResumableJob() async throws {
        let queue = try makeQueue()
        let sourceId = try await insertSource(queue)
        let repo = ImportJobRepository(writer: queue)

        let first = try await repo.startOrResume(sourceId: sourceId, sourceKind: "dropbox")
        try await repo.markRunning(jobId: first.id)
        let second = try await repo.startOrResume(sourceId: sourceId, sourceKind: "dropbox")

        XCTAssertEqual(first.id, second.id, "a resumable in-flight job must be reused, not duplicated")
    }

    func testStartOrResumeIgnoresTerminalJobAndStartsFresh() async throws {
        let queue = try makeQueue()
        let sourceId = try await insertSource(queue)
        let repo = ImportJobRepository(writer: queue)

        let first = try await repo.startOrResume(sourceId: sourceId, sourceKind: "dropbox")
        _ = try await repo.recordBatch(jobId: first.id, enumerationComplete: true)
        _ = try await repo.completeIfDone(jobId: first.id)
        let completed = try await repo.job(id: first.id)
        XCTAssertEqual(completed?.state, .complete)

        let second = try await repo.startOrResume(sourceId: sourceId, sourceKind: "dropbox")
        XCTAssertNotEqual(first.id, second.id, "a new request after completion starts a fresh job")
    }

    func testRecordBatchDiscoveredIncrementsDiscoveredCount() async throws {
        let queue = try makeQueue()
        let sourceId = try await insertSource(queue)
        let repo = ImportJobRepository(writer: queue)
        let job = try await repo.startOrResume(sourceId: sourceId, sourceKind: "dropbox")

        let result = try await repo.recordBatch(
            jobId: job.id, discoveredIdentities: ["a", "b", "c"], providerCursor: "cursor-1")
        XCTAssertEqual(result.itemsChanged, 3)

        let updated = try await repo.job(id: job.id)
        XCTAssertEqual(updated?.discoveredCount, 3)
        XCTAssertEqual(updated?.providerCursor, "cursor-1")
    }

    func testRecordBatchImportedSetsResultingTrackIdAndCount() async throws {
        let queue = try makeQueue()
        let sourceId = try await insertSource(queue)
        let trackId = try await insertTrack(queue, sourceId: sourceId)
        let repo = ImportJobRepository(writer: queue)
        let job = try await repo.startOrResume(sourceId: sourceId, sourceKind: "dropbox")

        _ = try await repo.recordBatch(
            jobId: job.id, importedItems: [(identity: "track-1", trackId: trackId)])

        let updated = try await repo.job(id: job.id)
        XCTAssertEqual(updated?.importedCount, 1)
        XCTAssertEqual(updated?.discoveredCount, 1, "an imported item that was never separately discovered still counts as discovered")

        let item = try await repo.item(jobId: job.id, identity: "track-1")
        XCTAssertEqual(item?.state, .imported)
        XCTAssertEqual(item?.resultingTrackId, trackId)
    }

    /// Plan §5: "replay its enumeration with idempotent item identities" —
    /// re-running the exact same batch (as a crash-recovery replay would)
    /// must not double-count or duplicate rows.
    func testReplayingIdenticalBatchIsIdempotent() async throws {
        let queue = try makeQueue()
        let sourceId = try await insertSource(queue)
        let track1 = try await insertTrack(queue, sourceId: sourceId, title: "Track 1")
        let track2 = try await insertTrack(queue, sourceId: sourceId, title: "Track 2")
        let repo = ImportJobRepository(writer: queue)
        let job = try await repo.startOrResume(sourceId: sourceId, sourceKind: "dropbox")

        let batch: [(identity: String, trackId: Int64)] = [
            (identity: "track-1", trackId: track1), (identity: "track-2", trackId: track2),
        ]
        let first = try await repo.recordBatch(jobId: job.id, importedItems: batch)
        XCTAssertEqual(first.itemsChanged, 2)

        let replay = try await repo.recordBatch(jobId: job.id, importedItems: batch)
        XCTAssertEqual(replay.itemsChanged, 0, "identical replay must be a no-op")

        let updated = try await repo.job(id: job.id)
        XCTAssertEqual(updated?.importedCount, 2, "counts must not double after replay")

        let itemCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_import_item")!
        }
        XCTAssertEqual(itemCount, 2, "replay must not duplicate item rows")
    }

    /// A retried item that failed once and later succeeds must transition
    /// counts correctly rather than double-counting across both states.
    func testFailedThenRetriedImportedTransitionsCountsCorrectly() async throws {
        let queue = try makeQueue()
        let sourceId = try await insertSource(queue)
        let trackId = try await insertTrack(queue, sourceId: sourceId)
        let repo = ImportJobRepository(writer: queue)
        let job = try await repo.startOrResume(sourceId: sourceId, sourceKind: "dropbox")

        _ = try await repo.recordBatch(
            jobId: job.id, failedItems: [(identity: "track-1", error: "network timeout")])
        var updated = try await repo.job(id: job.id)
        XCTAssertEqual(updated?.failedCount, 1)
        XCTAssertEqual(updated?.importedCount, 0)

        _ = try await repo.recordBatch(
            jobId: job.id, importedItems: [(identity: "track-1", trackId: trackId)])
        updated = try await repo.job(id: job.id)
        XCTAssertEqual(updated?.failedCount, 0, "retry success must un-count the earlier failure")
        XCTAssertEqual(updated?.importedCount, 1)

        let item = try await repo.item(jobId: job.id, identity: "track-1")
        XCTAssertEqual(item?.state, .imported)
        XCTAssertEqual(item?.resultingTrackId, trackId)
    }

    func testCompleteIfDoneRequiresEnumerationCompleteAndNoPendingItems() async throws {
        let queue = try makeQueue()
        let sourceId = try await insertSource(queue)
        let trackId = try await insertTrack(queue, sourceId: sourceId)
        let repo = ImportJobRepository(writer: queue)
        let job = try await repo.startOrResume(sourceId: sourceId, sourceKind: "dropbox")

        _ = try await repo.recordBatch(jobId: job.id, discoveredIdentities: ["a"])
        var completed = try await repo.completeIfDone(jobId: job.id)
        XCTAssertFalse(completed, "enumeration not yet marked complete")

        _ = try await repo.recordBatch(jobId: job.id, enumerationComplete: true)
        completed = try await repo.completeIfDone(jobId: job.id)
        XCTAssertFalse(completed, "item 'a' is still pending — not done yet")

        _ = try await repo.recordBatch(
            jobId: job.id, importedItems: [(identity: "a", trackId: trackId)])
        completed = try await repo.completeIfDone(jobId: job.id)
        XCTAssertTrue(completed)
        let final = try await repo.job(id: job.id)
        XCTAssertEqual(final?.state, .complete)
    }

    /// Plan §5: "Import cancellation stops enumeration at a checkpoint;
    /// already imported tracks remain."
    func testCancelDoesNotRemoveAlreadyImportedItems() async throws {
        let queue = try makeQueue()
        let sourceId = try await insertSource(queue)
        let trackId = try await insertTrack(queue, sourceId: sourceId)
        let repo = ImportJobRepository(writer: queue)
        let job = try await repo.startOrResume(sourceId: sourceId, sourceKind: "dropbox")

        _ = try await repo.recordBatch(
            jobId: job.id, importedItems: [(identity: "a", trackId: trackId)])
        try await repo.cancel(jobId: job.id)

        let updated = try await repo.job(id: job.id)
        XCTAssertEqual(updated?.state, .cancelled)
        let item = try await repo.item(jobId: job.id, identity: "a")
        XCTAssertEqual(item?.state, .imported, "cancellation must not revert already-imported items")
    }

    /// Plan §5: "Interrupted jobs return to queued/retryable on launch."
    func testRecoverInterruptedAtLaunchResetsRunningToQueued() async throws {
        let queue = try makeQueue()
        let sourceId = try await insertSource(queue)
        let repo = ImportJobRepository(writer: queue)
        let job = try await repo.startOrResume(sourceId: sourceId, sourceKind: "dropbox")
        try await repo.markRunning(jobId: job.id)

        // Simulate a fresh process instance over the same on-disk queue.
        let relaunchedRepo = ImportJobRepository(writer: queue)
        let resetCount = try await relaunchedRepo.recoverInterruptedAtLaunch()
        XCTAssertEqual(resetCount, 1)

        let recovered = try await relaunchedRepo.job(id: job.id)
        XCTAssertEqual(recovered?.state, .queued)
    }

    /// Plan §5: "If a provider has no resumable cursor, replay its
    /// enumeration with idempotent item identities." A caller resuming
    /// without a cursor needs the full set of already-recorded identities to
    /// skip.
    func testRecordedIdentitiesSupportsCursorlessResume() async throws {
        let queue = try makeQueue()
        let sourceId = try await insertSource(queue)
        let trackId = try await insertTrack(queue, sourceId: sourceId)
        let repo = ImportJobRepository(writer: queue)
        let job = try await repo.startOrResume(sourceId: sourceId, sourceKind: "dropbox")

        _ = try await repo.recordBatch(
            jobId: job.id,
            discoveredIdentities: ["a", "b"],
            importedItems: [(identity: "c", trackId: trackId)])

        let identities = try await repo.recordedIdentities(jobId: job.id)
        XCTAssertEqual(identities, ["a", "b", "c"])
    }
}
