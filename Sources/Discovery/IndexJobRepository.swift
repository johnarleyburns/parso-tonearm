import Foundation
import GRDB
import TonearmCore

/// Durable job-queue transactions for `discovery_index_job` (plan §3/§4/§6).
///
/// This repository is the ONLY place that mutates `discovery_index_job` and
/// `discovery_window_checkpoint` rows. It accepts `any DatabaseWriter` so it
/// can run against `LibraryStore.dbQueue` (the single core writer) without
/// TonearmDiscovery opening a second database (plan §3).
///
/// Lease/retry contract (plan §11 C03):
/// - Retry backoff: 30s, 2min, 10min, 1h; after 5 transient failures the job
///   moves to `.failed` and requires manual retry (does not auto-retry).
/// - Waiting states (`waitingForModel`/`waitingForAsset`/`waitingForNetwork`/
///   `waitingForPower`/`waitingForCooling`) do NOT consume a retry attempt —
///   only actual transient failures do (plan §11: "Waiting on model/power/
///   network does NOT consume retry attempts").
/// - Every mutation after work (progress/complete/fail) is guarded by the
///   caller's lease token in the same transaction; a stale/mismatched token
///   is silently discarded rather than applied (plan §4: "Every final write
///   checks track/asset existence, revision and lease token in the same
///   transaction; stale results are discarded").
public actor IndexJobRepository {
    public static let retryBackoffSeconds: [TimeInterval] = [30, 120, 600, 3600]
    public static let maxTransientFailures = 5
    public static let defaultLeaseDuration: TimeInterval = 120

    private let writer: any DatabaseWriter
    private let clock: () -> Date

    public init(writer: any DatabaseWriter, clock: @escaping () -> Date = Date.init) {
        self.writer = writer
        self.clock = clock
    }

    /// Result of a stale-lease reset at process launch, for diagnostics.
    public struct RecoveryResult: Equatable, Sendable {
        public let resetJobCount: Int
    }

    /// Reset any job left `.running` by a prior process instance back to
    /// `.queued`, clearing its lease. Must run once per process launch,
    /// before the scheduler starts claiming jobs (plan §7: "At process
    /// launch, reset stale running leases from the prior process to
    /// queued; only one scheduler exists per process").
    @discardableResult
    public func recoverStaleLeasesAtLaunch() throws -> RecoveryResult {
        try writer.write { db in
            let now = self.clock()
            let staleIDs = try String.fetchAll(
                db,
                sql: "SELECT id FROM discovery_index_job WHERE state = ?",
                arguments: ["running"])
            guard !staleIDs.isEmpty else { return RecoveryResult(resetJobCount: 0) }
            try db.execute(
                sql: """
                    UPDATE discovery_index_job
                    SET state = ?, leaseToken = NULL, leaseExpiresAt = NULL, updatedAt = ?
                    WHERE state = ?
                    """,
                arguments: ["queued", now, "running"])
            return RecoveryResult(resetJobCount: staleIDs.count)
        }
    }

    /// Ensure exactly one active job exists for (trackId, pipelineVersion).
    /// If one already exists and `restart` is false, it is left untouched
    /// (idempotent bootstrap/outbox replay). If `restart` is true (asset
    /// content actually changed), the existing job is reset to `.queued`
    /// with a fresh revision, attempt count and checkpoints cleared.
    @discardableResult
    public func enqueueOrRestart(
        trackId: Int64,
        selectedAssetId: Int64?,
        assetRevision: Int64?,
        pipelineVersion: Int,
        priority: Int = 0,
        restart: Bool = false
    ) throws -> DiscoveryIndexJob {
        try writer.write { db in
            let now = self.clock()
            if let existing = try DiscoveryIndexJob
                .filter(Column("trackId") == trackId)
                .filter(Column("pipelineVersion") == pipelineVersion)
                .fetchOne(db)
            {
                guard restart else { return existing }
                var restarted = existing
                restarted.selectedAssetId = selectedAssetId
                restarted.assetRevision = assetRevision
                restarted.state = .queued
                restarted.priority = priority
                restarted.updatedAt = now
                restarted.nextAttemptAt = nil
                restarted.attemptCount = 0
                restarted.leaseToken = nil
                restarted.leaseExpiresAt = nil
                restarted.completedWindows = 0
                restarted.totalWindows = 0
                restarted.embeddingStageState = .pending
                restarted.musicalAnalysisStageState = .pending
                restarted.errorCode = nil
                restarted.errorMessage = nil
                try restarted.update(db)
                try DiscoveryWindowCheckpoint
                    .filter(Column("jobId") == existing.id)
                    .deleteAll(db)
                return restarted
            }
            var job = DiscoveryIndexJob(
                trackId: trackId,
                selectedAssetId: selectedAssetId,
                assetRevision: assetRevision,
                pipelineVersion: pipelineVersion,
                priority: priority,
                createdAt: now,
                updatedAt: now)
            try job.insert(db)
            return job
        }
    }

    /// A claimed job plus the lease token the caller must present back for
    /// every subsequent mutation of this job.
    public struct Claim: Equatable, Sendable {
        public let job: DiscoveryIndexJob
        public let leaseToken: String
    }

    /// Atomically claim the highest-priority eligible job: `queued`, or
    /// `retryScheduled`/`waitingFor*` whose `nextAttemptAt` has passed, or a
    /// `running` job whose lease has expired (a crashed prior claim).
    /// Priority: selected-track request > newly imported > oldest backlog,
    /// approximated here by `priority DESC, createdAt ASC` (plan §6 age
    /// promotion is realized by the scheduler bumping `priority` over time,
    /// not by this repository).
    public func claimNextJob(leaseDuration: TimeInterval = defaultLeaseDuration) throws -> Claim? {
        try writer.write { db in
            let now = self.clock()
            let eligible = try DiscoveryIndexJob
                .filter(
                    sql: """
                        (state = 'queued')
                        OR (state IN ('retryScheduled', 'waitingForModel', 'waitingForAsset',
                                       'waitingForNetwork', 'waitingForPower', 'waitingForCooling')
                            AND (nextAttemptAt IS NULL OR nextAttemptAt <= ?))
                        OR (state = 'running' AND leaseExpiresAt IS NOT NULL AND leaseExpiresAt < ?)
                        """,
                    arguments: [now, now])
                .order(Column("priority").desc, Column("createdAt").asc)
                .fetchOne(db)
            guard var job = eligible else { return nil }

            let token = UUID().uuidString
            job.state = .running
            job.leaseToken = token
            job.leaseExpiresAt = now.addingTimeInterval(leaseDuration)
            job.updatedAt = now
            try job.update(db)
            return Claim(job: job, leaseToken: token)
        }
    }

    /// Persist one completed window checkpoint and bump progress, guarded by
    /// lease token. Discarded (no-op) if the token is stale.
    public func recordWindowCompletion(
        jobId: String,
        leaseToken: String,
        checkpoint: DiscoveryWindowCheckpoint,
        totalWindows: Int
    ) throws {
        try writer.write { db in
            guard var job = try DiscoveryIndexJob.fetchOne(db, key: jobId),
                job.leaseToken == leaseToken
            else { return }
            var cp = checkpoint
            try cp.insert(db, onConflict: .replace)
            job.completedWindows = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM discovery_window_checkpoint WHERE jobId = ?",
                arguments: [jobId]) ?? job.completedWindows
            job.totalWindows = totalWindows
            job.updatedAt = self.clock()
            try job.update(db)
        }
    }

    /// Mark a stage terminal for the job holding `leaseToken`. Embedding
    /// completion and musical-analysis coverage are independently
    /// observable (plan §4/§6): a musical-analysis failure never blocks
    /// embedding-derived search coverage.
    public func completeStage(
        jobId: String,
        leaseToken: String,
        stage: Stage,
        state: DiscoveryStageState
    ) throws {
        try writer.write { db in
            guard var job = try DiscoveryIndexJob.fetchOne(db, key: jobId),
                job.leaseToken == leaseToken
            else { return }
            switch stage {
            case .embedding: job.embeddingStageState = state
            case .musicalAnalysis: job.musicalAnalysisStageState = state
            }
            job.updatedAt = self.clock()
            if job.isComplete {
                job.state = .complete
                job.leaseToken = nil
                job.leaseExpiresAt = nil
            }
            try job.update(db)
        }
    }

    public enum Stage: Sendable { case embedding, musicalAnalysis }

    /// A job could not make progress for a non-transient reason (model not
    /// ready, asset unavailable, offline, low power, thermal). Waiting does
    /// NOT consume a retry attempt (plan §11).
    public func markWaiting(
        jobId: String, leaseToken: String, reason: DiscoveryJobState, retryAfter: TimeInterval?
    ) throws {
        try writer.write { db in
            guard var job = try DiscoveryIndexJob.fetchOne(db, key: jobId),
                job.leaseToken == leaseToken
            else { return }
            job.state = reason
            job.nextAttemptAt = retryAfter.map { self.clock().addingTimeInterval($0) }
            job.updatedAt = self.clock()
            try job.update(db)
        }
    }

    /// A transient failure (decode error, transient model error, etc.).
    /// Consumes one attempt; schedules the next backoff tier, or moves to
    /// `.failed` (manual retry required) after
    /// `maxTransientFailures` (plan §11: "30 s, 2 min, 10 min, 1 h; max 5
    /// transient failures then manual retry").
    public func recordTransientFailure(
        jobId: String, leaseToken: String, errorCode: String, errorMessage: String?
    ) throws {
        try writer.write { db in
            guard var job = try DiscoveryIndexJob.fetchOne(db, key: jobId),
                job.leaseToken == leaseToken
            else { return }
            job.attemptCount += 1
            job.errorCode = errorCode
            job.errorMessage = errorMessage
            job.updatedAt = self.clock()
            if job.attemptCount >= Self.maxTransientFailures {
                job.state = .failed
                job.nextAttemptAt = nil
                job.leaseToken = nil
                job.leaseExpiresAt = nil
            } else {
                let tierIndex = min(job.attemptCount - 1, Self.retryBackoffSeconds.count - 1)
                let delay = Self.retryBackoffSeconds[max(0, tierIndex)]
                job.state = .retryScheduled
                job.nextAttemptAt = self.clock().addingTimeInterval(delay)
                job.leaseToken = nil
                job.leaseExpiresAt = nil
            }
            try job.update(db)
        }
    }

    /// Manual retry: an owner/user action that resets a `.failed` job back
    /// to `.queued` without incrementing content revision, ignoring the
    /// attempt-count ceiling (plan §11: "Retry does not reset completed
    /// tracks" — this only applies to jobs not already `.isComplete`).
    public func manualRetry(jobId: String) throws {
        try writer.write { db in
            guard var job = try DiscoveryIndexJob.fetchOne(db, key: jobId), !job.isComplete else {
                return
            }
            job.state = .queued
            job.attemptCount = 0
            job.nextAttemptAt = nil
            job.errorCode = nil
            job.errorMessage = nil
            job.updatedAt = self.clock()
            try job.update(db)
        }
    }

    /// Retry every `.failed` job for a pipeline version at once — the status
    /// UI's "Retry failed" action (plan §10 action 4). Completed jobs are
    /// never touched ("Retry does not reset completed tracks"). Returns the
    /// number of jobs re-queued.
    @discardableResult
    public func retryAllFailed(pipelineVersion: Int) throws -> Int {
        try writer.write { db in
            let failed = try DiscoveryIndexJob
                .filter(Column("pipelineVersion") == pipelineVersion)
                .filter(Column("state") == DiscoveryJobState.failed.rawValue)
                .fetchAll(db)
            for var job in failed where !job.isComplete {
                job.state = .queued
                job.attemptCount = 0
                job.nextAttemptAt = nil
                job.errorCode = nil
                job.errorMessage = nil
                job.updatedAt = self.clock()
                try job.update(db)
            }
            return failed.count
        }
    }

    /// Release a claimed job back to `.queued` with no waiting reason and no
    /// retry-attempt penalty — used by `IndexScheduler` for scheduler-level
    /// gates that have no dedicated persisted `DiscoveryJobState` (user
    /// pause, playback priority, missing background grant): plan §4 rules
    /// these out as "thousands of per-track mutations", so instead of
    /// inventing a new state the job simply becomes immediately reclaimable
    /// again once the gate clears. Discarded (no-op) if the token is stale.
    public func releaseToQueued(jobId: String, leaseToken: String) throws {
        try writer.write { db in
            guard var job = try DiscoveryIndexJob.fetchOne(db, key: jobId),
                job.leaseToken == leaseToken
            else { return }
            job.state = .queued
            job.leaseToken = nil
            job.leaseExpiresAt = nil
            job.updatedAt = self.clock()
            try job.update(db)
        }
    }

    public func job(id: String) throws -> DiscoveryIndexJob? {
        try writer.read { db in try DiscoveryIndexJob.fetchOne(db, key: id) }
    }

    /// Removes one job row outright — used when a track stops being
    /// eligible for indexing at all (its only assets became remote/cloud
    /// and un-downloaded), rather than leaving it parked in a state it can
    /// never resolve out of on its own.
    public func deleteJob(id: String) throws {
        _ = try writer.write { db in
            try DiscoveryIndexJob.deleteOne(db, key: id)
        }
    }

    public func job(trackId: Int64, pipelineVersion: Int) throws -> DiscoveryIndexJob? {
        try writer.read { db in
            try DiscoveryIndexJob
                .filter(Column("trackId") == trackId)
                .filter(Column("pipelineVersion") == pipelineVersion)
                .fetchOne(db)
        }
    }

    public func completedWindowIndices(jobId: String) throws -> Set<Int> {
        try writer.read { db in
            let indices = try Int.fetchAll(
                db,
                sql: "SELECT windowIndex FROM discovery_window_checkpoint WHERE jobId = ?",
                arguments: [jobId])
            return Set(indices)
        }
    }

    /// One representative (job's own) transient-failure error, for the status
    /// surface's "why" text — never a fabricated or generic string.
    public struct JobErrorSample: Equatable, Sendable {
        public let code: String
        public let message: String?
    }

    /// Coverage counts for the whole catalog scope, derived before musical
    /// filters (plan §9): total/complete/waiting/failed by job state.
    public struct Coverage: Equatable, Sendable {
        public let total: Int
        public let complete: Int
        public let queuedOrRunning: Int
        public let waiting: Int
        public let failed: Int
        /// Per-`DiscoveryJobState` counts within the `waiting` bucket above —
        /// "waiting" alone collapses genuinely distinct reasons (no reachable
        /// asset, offline, backed off after a transient failure, model not
        /// ready, thermal/power) into one indistinguishable number, which is
        /// exactly what produced the reported "non-statement" status text
        /// ("Waiting to continue. Indexing resumes when conditions allow.")
        /// that never says which of those it actually is.
        public let waitingBreakdown: [DiscoveryJobState: Int]
        /// The most recently recorded transient-failure error among jobs
        /// currently `.retryScheduled` or `.failed`, if any — real error text
        /// from the actual attempt, not a synthesized explanation. `nil` when
        /// no job has ever recorded one (e.g. every wait is a clean
        /// asset/network/model/power/cooling gate with no failure attempt).
        public let mostRecentFailureError: JobErrorSample?
    }

    public func coverage(pipelineVersion: Int) throws -> Coverage {
        try writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT state, COUNT(*) AS c FROM discovery_index_job
                    WHERE pipelineVersion = ? GROUP BY state
                    """,
                arguments: [pipelineVersion])
            var byState: [String: Int] = [:]
            for row in rows {
                byState[row["state"] as String] = row["c"] as Int
            }
            let waitingStates: [DiscoveryJobState] = [
                .waitingForModel, .waitingForAsset, .waitingForNetwork, .waitingForPower,
                .waitingForCooling, .retryScheduled,
            ]
            let total = byState.values.reduce(0, +)
            let complete = byState["complete"] ?? 0
            let failed = byState["failed"] ?? 0
            let queuedOrRunning = (byState["queued"] ?? 0) + (byState["running"] ?? 0)
            var waitingBreakdown: [DiscoveryJobState: Int] = [:]
            for state in waitingStates {
                if let count = byState[state.rawValue], count > 0 { waitingBreakdown[state] = count }
            }
            let waiting = waitingBreakdown.values.reduce(0, +)

            let errorRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT errorCode, errorMessage FROM discovery_index_job
                    WHERE pipelineVersion = ? AND state IN ('retryScheduled', 'failed')
                        AND errorCode IS NOT NULL
                    ORDER BY updatedAt DESC LIMIT 1
                    """,
                arguments: [pipelineVersion])
            let mostRecentFailureError: JobErrorSample? = errorRow.flatMap { row in
                (row["errorCode"] as String?).map { code in
                    JobErrorSample(code: code, message: row["errorMessage"] as String?)
                }
            }

            return Coverage(
                total: total, complete: complete, queuedOrRunning: queuedOrRunning,
                waiting: waiting, failed: failed,
                waitingBreakdown: waitingBreakdown, mostRecentFailureError: mostRecentFailureError)
        }
    }
}
