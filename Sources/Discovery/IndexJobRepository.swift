import Foundation
import GRDB
import TonearmCore

/// Durable job-queue transactions for `discovery_index_job`.
///
/// This repository is the ONLY place that mutates `discovery_index_job` rows.
/// It accepts `any DatabaseWriter` so it can run against
/// `LibraryStore.dbQueue` (the single core writer) without
/// TonearmDiscovery opening a second database (plan §3).
///
/// Lease/retry contract (plan §11 C03):
/// - Retry backoff: 30s, 2min, 10min, 1h; after 5 transient failures the job
///   moves to `.failed` and requires manual retry (does not auto-retry).
/// - Waiting states (`waitingForAsset`/`waitingForNetwork`/`waitingForPower`/
///   `waitingForCooling`) do NOT consume a retry attempt — only actual
///   transient failures do.
/// - Every mutation after work (progress/complete/fail) is guarded by the
///   caller's lease token in the same transaction; a stale/mismatched token
///   is silently discarded rather than applied.
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
    /// before the scheduler starts claiming jobs.
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
    /// with a fresh revision and attempt count.
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
                restarted.musicalAnalysisStageState = .pending
                restarted.errorCode = nil
                restarted.errorMessage = nil
                try restarted.update(db)
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

    /// Re-queue only musical analysis after an algorithm/version migration.
    @discardableResult
    public func requeueMusicalAnalysis(
        trackId: Int64,
        selectedAssetId: Int64?,
        assetRevision: Int64?,
        pipelineVersion: Int
    ) throws -> DiscoveryIndexJob? {
        try writer.write { db in
            guard var job = try DiscoveryIndexJob
                .filter(Column("trackId") == trackId)
                .filter(Column("pipelineVersion") == pipelineVersion)
                .fetchOne(db)
            else { return nil }

            job.selectedAssetId = selectedAssetId
            job.assetRevision = assetRevision
            job.musicalAnalysisStageState = .pending
            job.state = .queued
            job.nextAttemptAt = nil
            job.attemptCount = 0
            job.leaseToken = nil
            job.leaseExpiresAt = nil
            job.errorCode = nil
            job.errorMessage = nil
            job.updatedAt = self.clock()
            try job.update(db)
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
    /// approximated here by `priority DESC, createdAt ASC`.
    public func claimNextJob(leaseDuration: TimeInterval = defaultLeaseDuration) throws -> Claim? {
        try writer.write { db in
            let now = self.clock()
            let eligible = try DiscoveryIndexJob
                .filter(
                    sql: """
                        (state = 'queued')
                        OR (state IN ('retryScheduled', 'waitingForAsset',
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

    /// Mark the musical-analysis stage terminal for the job holding
    /// `leaseToken`.
    public func completeMusicalAnalysis(
        jobId: String,
        leaseToken: String,
        state: DiscoveryStageState
    ) throws {
        try writer.write { db in
            guard var job = try DiscoveryIndexJob.fetchOne(db, key: jobId),
                job.leaseToken == leaseToken
            else { return }
            job.musicalAnalysisStageState = state
            job.updatedAt = self.clock()
            switch state {
            case .complete: job.state = .complete
            case .failed: job.state = .failed
            case .unsupported: job.state = .unsupported
            case .pending, .running: job.state = .running
            }
            job.leaseToken = nil
            job.leaseExpiresAt = nil
            try job.update(db)
        }
    }

    /// A job could not make progress for a non-transient reason (asset
    /// unavailable, offline, low power, thermal). Waiting does NOT consume a
    /// retry attempt.
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

    /// A transient failure (decode error, read error, etc.). Consumes one
    /// attempt; schedules the next backoff tier, or moves to `.failed`
    /// (manual retry required) after `maxTransientFailures`.
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
    /// attempt-count ceiling ("Retry does not reset completed tracks").
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
    /// UI's "Retry failed" action. Completed jobs are never touched.
    @discardableResult
    public func retryAllFailed(pipelineVersion: Int) throws -> Int {
        try writer.write { db in
            let failed = try DiscoveryIndexJob.fetchAll(
                db,
                sql: """
                    SELECT * FROM discovery_index_job
                    WHERE pipelineVersion = ?
                      AND (state = 'failed' OR state = 'unsupported')
                    """,
                arguments: [pipelineVersion])
            for var job in failed {
                job.state = .queued
                job.musicalAnalysisStageState = .pending
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
    /// pause, missing background grant). Discarded if the token is stale.
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
    /// eligible for indexing at all rather than leaving it parked forever.
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

    /// One representative (job's own) transient-failure error, for the status
    /// surface's "why" text — never a fabricated or generic string.
    public struct JobErrorSample: Equatable, Sendable {
        public let code: String
        public let message: String?
    }

    /// Coverage counts for the whole catalog scope, derived before musical
    /// filters: total/complete/waiting/failed by job state.
    public struct Coverage: Equatable, Sendable {
        public let total: Int
        public let complete: Int
        public let queuedOrRunning: Int
        public let waiting: Int
        public let failed: Int
        /// Per-`DiscoveryJobState` counts within the `waiting` bucket above —
        /// "waiting" alone collapses genuinely distinct reasons (no reachable
        /// asset, offline, backed off after a transient failure, thermal/power)
        /// into one indistinguishable number.
        public let waitingBreakdown: [DiscoveryJobState: Int]
        /// The most recently recorded transient-failure error among jobs
        /// currently `.retryScheduled` or `.failed`, if any.
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
                .waitingForAsset, .waitingForNetwork, .waitingForPower,
                .waitingForCooling, .retryScheduled,
            ]
            let total = byState.values.reduce(0, +)
            let complete = byState["complete"] ?? 0
            let failed = (byState["failed"] ?? 0) + (byState["unsupported"] ?? 0)
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

    // MARK: - Per-track detail

    /// Which `countsCard` row a caller tapped — mirrors `Coverage`'s own bucketing exactly.
    public enum TrackListBucket: String, Equatable, Hashable, Identifiable, CaseIterable, Sendable {
        case complete, queuedOrRunning, waiting, failed
        public var id: String { rawValue }
    }

    /// One row for the detail list.
    public struct TrackSummary: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let title: String
        public let artistName: String?
        /// The specific waiting/failure reason, when the bucket has one.
        public let detail: String?
    }

    /// Whether `assetId` is a `.remote` asset (needs network bytes to index).
    public func isRemoteAsset(assetId: Int64) throws -> Bool {
        try writer.read { db in
            try Asset.fetchOne(db, key: assetId)?.kind == .remote
        }
    }

    /// Up to `limit` tracks in `bucket`, alphabetical by title.
    public func trackSummaries(
        for bucket: TrackListBucket, pipelineVersion: Int, limit: Int = 500
    ) throws -> [TrackSummary] {
        let states: [String]
        switch bucket {
        case .complete: states = ["complete"]
        case .queuedOrRunning: states = ["queued", "running"]
        case .waiting:
            states = [
                DiscoveryJobState.waitingForAsset, .waitingForNetwork, .waitingForPower,
                .waitingForCooling, .retryScheduled,
            ].map(\.rawValue)
        case .failed: states = ["failed", "unsupported"]
        }
        var args: [DatabaseValueConvertible?] = [pipelineVersion]
        args.append(contentsOf: states.map { $0 as DatabaseValueConvertible? })
        args.append(limit)
        return try writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT t.id AS trackId, t.title AS title, a.name AS artistName,
                           j.errorMessage AS errorMessage
                    FROM discovery_index_job j
                    JOIN track t ON t.id = j.trackId
                    LEFT JOIN artist a ON a.id = t.artistId
                    WHERE j.pipelineVersion = ? AND j.state IN (\(states.map { _ in "?" }.joined(separator: ",")))
                    ORDER BY t.title COLLATE NOCASE
                    LIMIT ?
                    """,
                arguments: StatementArguments(args))
                .map { row in
                    TrackSummary(
                        id: row["trackId"] as Int64, title: row["title"] as String,
                        artistName: row["artistName"] as String?,
                        detail: row["errorMessage"] as String?)
                }
        }
    }

    // MARK: - Live per-track status + ETA

    /// The one track currently being actively worked on, if any — `nil` when
    /// nothing holds a `running` lease right now.
    public struct RunningTrackSummary: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let title: String
        public let artistName: String?
    }

    public func currentlyRunningTrack(pipelineVersion: Int) throws -> RunningTrackSummary? {
        try writer.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT t.id AS trackId, t.title AS title, a.name AS artistName
                    FROM discovery_index_job j
                    JOIN track t ON t.id = j.trackId
                    LEFT JOIN artist a ON a.id = t.artistId
                    WHERE j.pipelineVersion = ? AND j.state = 'running'
                    ORDER BY j.updatedAt DESC
                    LIMIT 1
                    """,
                arguments: [pipelineVersion]
            ).map { row in
                RunningTrackSummary(
                    id: row["trackId"] as Int64, title: row["title"] as String,
                    artistName: row["artistName"] as String?)
            }
        }
    }

    /// Tracks completed per second, measured over the real wall-clock trailing `window` (default
    /// 5 minutes) rather than per-job duration. `nil` when nothing has completed in that window —
    /// honestly "can't estimate yet" rather than a fabricated rate.
    public func recentCompletionRate(
        pipelineVersion: Int, window: TimeInterval = 300, now: Date? = nil
    ) throws -> Double? {
        let cutoff = (now ?? clock()).addingTimeInterval(-window)
        let count = try writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM discovery_index_job
                    WHERE pipelineVersion = ? AND state = 'complete' AND updatedAt >= ?
                    """,
                arguments: [pipelineVersion, cutoff]) ?? 0
        }
        guard count > 0 else { return nil }
        return Double(count) / window
    }
}
