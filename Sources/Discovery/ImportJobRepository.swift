import Foundation
import GRDB
import TonearmCore

/// Durable import job/item persistence for `discovery_import_job`/
/// `discovery_import_item` (plan §4/§5). This is the import-side durability
/// slice explicitly left undone by sessions 1-3 ("the record types already
/// exist ... but nothing reads/writes them yet").
///
/// Contract (plan §5):
/// - "Persist import job state BEFORE enumeration." Callers must
///   `startOrResume` (which persists the job row) before doing any provider
///   enumeration work.
/// - "Commit each bounded batch and its cursor/item checkpoints together."
///   `recordBatch` commits discovered/imported/failed/skipped item
///   transitions, the provider cursor and `enumerationComplete` in one
///   transaction.
/// - "If a provider has no resumable cursor, replay its enumeration with
///   idempotent item identities." `unique(jobId, identity)` plus this
///   repository's replay-safe upsert means re-running the same batch (same
///   identities, same outcomes) never double-counts or duplicates a track.
/// - "Interrupted jobs return to queued/retryable on launch."
///   `recoverInterruptedAtLaunch` resets any `.running` job to `.queued`,
///   mirroring `IndexJobRepository.recoverStaleLeasesAtLaunch`.
/// - "Import cancellation stops enumeration at a checkpoint; already
///   imported tracks remain." `cancel` only flips job state; it never
///   deletes item rows or their `resultingTrackId` tracks.
public actor ImportJobRepository {
    private let writer: any DatabaseWriter
    private let clock: () -> Date

    public init(writer: any DatabaseWriter, clock: @escaping () -> Date = Date.init) {
        self.writer = writer
        self.clock = clock
    }

    /// Resumable states: a caller retrying/resuming an enumeration should
    /// reuse the same durable job rather than starting a fresh one (so its
    /// already-recorded items/cursor are not lost). `.complete` and
    /// `.cancelled` are terminal — a new request for that source starts a
    /// fresh job.
    private static let resumableStates: Set<DiscoveryImportJobState> = [
        .queued, .running, .waitingForNetwork, .paused, .failed,
    ]

    /// Find the source's existing resumable job, or persist a brand-new one
    /// in `.queued`. Always returns a persisted row (plan §5: "Persist import
    /// job state BEFORE enumeration") — callers must not enumerate before
    /// calling this.
    @discardableResult
    public func startOrResume(sourceId: Int64?, sourceKind: String) throws -> DiscoveryImportJob {
        try writer.write { db in
            if let sourceId,
                let existing = try DiscoveryImportJob
                    .filter(Column("sourceId") == sourceId)
                    .fetchAll(db)
                    .first(where: { Self.resumableStates.contains($0.state) })
            {
                return existing
            }
            let now = self.clock()
            var job = DiscoveryImportJob(
                sourceId: sourceId, sourceKind: sourceKind, state: .queued,
                createdAt: now, updatedAt: now)
            try job.insert(db)
            return job
        }
    }

    /// Mark a persisted job `.running` right before enumeration begins.
    /// No-op if the job is already terminal (`.complete`/`.cancelled`).
    public func markRunning(jobId: String) throws {
        try writer.write { db in
            guard var job = try DiscoveryImportJob.fetchOne(db, key: jobId),
                job.state != .complete, job.state != .cancelled
            else { return }
            job.state = .running
            job.updatedAt = self.clock()
            try job.update(db)
        }
    }

    public func markWaitingForNetwork(jobId: String) throws {
        try writer.write { db in
            guard var job = try DiscoveryImportJob.fetchOne(db, key: jobId),
                job.state != .complete, job.state != .cancelled
            else { return }
            job.state = .waitingForNetwork
            job.updatedAt = self.clock()
            try job.update(db)
        }
    }

    /// Import cancellation: stop enumeration at the last committed
    /// checkpoint. Already-imported items/tracks are untouched (plan §5).
    public func cancel(jobId: String) throws {
        try writer.write { db in
            guard var job = try DiscoveryImportJob.fetchOne(db, key: jobId),
                job.state != .complete
            else { return }
            job.state = .cancelled
            job.updatedAt = self.clock()
            try job.update(db)
        }
    }

    /// One bounded enumeration batch's outcome, applied idempotently.
    public struct BatchResult: Equatable, Sendable {
        public let itemsChanged: Int
    }

    /// Commit one bounded enumeration batch: newly discovered item
    /// identities, terminal outcomes for items processed this batch, the
    /// provider's resumable cursor and (on the final page) enumeration
    /// completion — all in one transaction (plan §5).
    ///
    /// Replaying the exact same batch (e.g. after a crash mid-commit, with
    /// no cursor to skip past already-handled identities) is safe: an item
    /// already recorded in the target state is left untouched and does not
    /// re-increment `discoveredCount`/`importedCount`/`failedCount`.
    @discardableResult
    public func recordBatch(
        jobId: String,
        discoveredIdentities: [String] = [],
        importedItems: [(identity: String, trackId: Int64)] = [],
        failedItems: [(identity: String, error: String)] = [],
        skippedIdentities: [String] = [],
        providerCursor: String? = nil,
        enumerationComplete: Bool? = nil
    ) throws -> BatchResult {
        try writer.write { db in
            guard var job = try DiscoveryImportJob.fetchOne(db, key: jobId) else {
                return BatchResult(itemsChanged: 0)
            }
            var changed = 0

            for identity in discoveredIdentities {
                if try self.applyItem(
                    db: db, job: &job, identity: identity, outcome: .pending)
                {
                    changed += 1
                }
            }
            for entry in importedItems {
                if try self.applyItem(
                    db: db, job: &job, identity: entry.identity,
                    outcome: .imported(trackId: entry.trackId))
                {
                    changed += 1
                }
            }
            for entry in failedItems {
                if try self.applyItem(
                    db: db, job: &job, identity: entry.identity, outcome: .failed(error: entry.error)
                ) {
                    changed += 1
                }
            }
            for identity in skippedIdentities {
                if try self.applyItem(db: db, job: &job, identity: identity, outcome: .skipped) {
                    changed += 1
                }
            }

            if let providerCursor { job.providerCursor = providerCursor }
            if let enumerationComplete { job.enumerationComplete = enumerationComplete }
            job.updatedAt = self.clock()
            try job.update(db)
            return BatchResult(itemsChanged: changed)
        }
    }

    private enum ItemOutcome: Equatable {
        case pending
        case imported(trackId: Int64)
        case failed(error: String)
        case skipped
    }

    /// Apply one item's outcome, adjusting `job`'s counters so they always
    /// reflect exactly the current set of item rows (never double-counted
    /// across replays). Returns `true` if anything actually changed.
    @discardableResult
    private func applyItem(
        db: Database, job: inout DiscoveryImportJob, identity: String, outcome: ItemOutcome
    ) throws -> Bool {
        let newState: DiscoveryImportItemState
        var resultingTrackId: Int64?
        var error: String?
        switch outcome {
        case .pending: newState = .pending
        case .imported(let trackId): newState = .imported; resultingTrackId = trackId
        case .failed(let err): newState = .failed; error = err
        case .skipped: newState = .skipped
        }

        if var existing = try DiscoveryImportItem
            .filter(Column("jobId") == job.id)
            .filter(Column("itemIdentity") == identity)
            .fetchOne(db)
        {
            guard existing.state != newState || existing.resultingTrackId != resultingTrackId
            else {
                return false  // Exact replay of an already-recorded outcome: no-op.
            }
            if existing.state == .imported { job.importedCount -= 1 }
            if existing.state == .failed { job.failedCount -= 1 }
            existing.state = newState
            existing.resultingTrackId = resultingTrackId
            existing.error = error
            try existing.update(db)
        } else {
            var item = DiscoveryImportItem(
                jobId: job.id, itemIdentity: identity, state: newState,
                resultingTrackId: resultingTrackId, error: error)
            try item.insert(db)
            job.discoveredCount += 1
        }

        if newState == .imported { job.importedCount += 1 }
        if newState == .failed { job.failedCount += 1 }
        return true
    }

    /// Mark the job `.complete`. Only valid once enumeration finished and no
    /// item remains `.pending` (still needs a terminal outcome).
    @discardableResult
    public func completeIfDone(jobId: String) throws -> Bool {
        try writer.write { db in
            guard var job = try DiscoveryImportJob.fetchOne(db, key: jobId), job.enumerationComplete
            else { return false }
            let pendingCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM discovery_import_item
                    WHERE jobId = ? AND state = 'pending'
                    """, arguments: [jobId]) ?? 0
            guard pendingCount == 0 else { return false }
            job.state = .complete
            job.updatedAt = self.clock()
            try job.update(db)
            return true
        }
    }

    /// Reset any job left `.running` by a prior process instance back to
    /// `.queued` (plan §5: "Interrupted jobs return to queued/retryable on
    /// launch"). Mirrors `IndexJobRepository.recoverStaleLeasesAtLaunch`;
    /// import jobs have no lease token (enumeration is caller-driven, not
    /// claimed by a shared worker pool), so this is a plain state reset.
    @discardableResult
    public func recoverInterruptedAtLaunch() throws -> Int {
        try writer.write { db in
            let now = self.clock()
            let staleIDs = try String.fetchAll(
                db, sql: "SELECT id FROM discovery_import_job WHERE state = ?",
                arguments: ["running"])
            guard !staleIDs.isEmpty else { return 0 }
            try db.execute(
                sql: "UPDATE discovery_import_job SET state = ?, updatedAt = ? WHERE state = ?",
                arguments: ["queued", now, "running"])
            return staleIDs.count
        }
    }

    public func job(id: String) throws -> DiscoveryImportJob? {
        try writer.read { db in try DiscoveryImportJob.fetchOne(db, key: id) }
    }

    public func item(jobId: String, identity: String) throws -> DiscoveryImportItem? {
        try writer.read { db in
            try DiscoveryImportItem
                .filter(Column("jobId") == jobId)
                .filter(Column("itemIdentity") == identity)
                .fetchOne(db)
        }
    }

    /// Identities already recorded for this job — the durable checkpoint an
    /// enumerator without a provider cursor replays against so it never
    /// re-imports a track it already committed (plan §5).
    public func recordedIdentities(jobId: String) throws -> Set<String> {
        try writer.read { db in
            Set(
                try String.fetchAll(
                    db, sql: "SELECT itemIdentity FROM discovery_import_item WHERE jobId = ?",
                    arguments: [jobId]))
        }
    }
}
