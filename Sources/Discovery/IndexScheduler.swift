import Foundation
import TonearmCore

/// Drives `IndexJobRepository`'s queue against an `IndexJobExecuting`
/// worker, applying `IndexPolicy` gates before and between every bounded
/// unit of work (plan §6: "Cancellation is checked before/after each
/// window"; "Only ONE analysis job executes at a time"). Background and
/// foreground callers share this same scheduler/actor so a duplicate worker
/// can never run concurrently (plan §7).
///
/// This type does no decode/inference itself — see `IndexJobExecuting`.
/// The real C04 windowed-reader/model worker is not implemented this
/// session; this scheduler is fully exercised in tests against a synthetic
/// in-memory worker, which is exactly the seam the plan's own C04 note
/// sanctions ("synthetic test encoders for deterministic automation").
public actor IndexScheduler {
    private let jobs: IndexJobRepository
    private let worker: any IndexJobExecuting
    private let sleeper: @Sendable (TimeInterval) async -> Void

    public init(
        jobs: IndexJobRepository,
        worker: any IndexJobExecuting,
        sleeper: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            guard seconds > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.jobs = jobs
        self.worker = worker
        self.sleeper = sleeper
    }

    public enum TickOutcome: Equatable, Sendable {
        /// Policy blocked before any job was claimed; nothing started.
        case blocked(IndexBlockReason)
        /// No eligible job to claim right now.
        case idle
        /// The claimed job reached `.complete` (both stages terminal).
        case jobCompleted(jobId: String)
        /// The claimed job hit a non-transient wait reason mid-run.
        case jobWaiting(jobId: String, reason: DiscoveryJobState)
        /// The claimed job hit a transient failure and was scheduled for
        /// retry (or moved to `.failed` after the attempt ceiling).
        case jobFailed(jobId: String)
        /// A scheduler-level gate (no persisted job-state code exists for
        /// it) tripped mid-run; the job was released back to `.queued`
        /// untouched, no retry penalty.
        case jobPreempted(jobId: String, reason: IndexBlockReason)
    }

    /// Run one scheduling pass. `snapshotProvider` is called once before
    /// claiming and again before every subsequent bounded unit, so a test
    /// (or the real iOS adapter driving repeated ticks) can simulate
    /// conditions changing mid-job (thermal degrading, playback starting,
    /// user pausing) without the scheduler needing any live system access
    /// itself.
    @discardableResult
    public func tick(
        snapshotProvider: @Sendable () -> DiscoverySchedulingSnapshot
    ) async throws -> TickOutcome {
        let initialDecision = IndexPolicy.decide(snapshotProvider())
        guard case .proceed = initialDecision else {
            if case let .blocked(reason) = initialDecision { return .blocked(reason) }
            return .idle
        }

        guard let claim = try await jobs.claimNextJob() else { return .idle }
        var job = claim.job
        let token = claim.leaseToken

        while true {
            let gate = IndexPolicy.decide(snapshotProvider())
            guard case let .proceed(interWindowDelay) = gate else {
                guard case let .blocked(reason) = gate else { return .idle }
                try await releaseOrMarkWaiting(jobId: job.id, leaseToken: token, reason: reason)
                return .jobPreempted(jobId: job.id, reason: reason)
            }

            let outcome = await worker.processNextUnit(job: job, leaseToken: token)
            switch outcome {
            case .windowCompleted:
                guard let refreshed = try await jobs.job(id: job.id) else { return .idle }
                job = refreshed
                await sleeper(interWindowDelay)

            case .embeddingStageFinished(let state):
                try await jobs.completeStage(
                    jobId: job.id, leaseToken: token, stage: .embedding, state: state)
                guard let refreshed = try await jobs.job(id: job.id) else { return .idle }
                job = refreshed
                if refreshed.isComplete { return .jobCompleted(jobId: job.id) }

            case .musicalAnalysisStageFinished(let state):
                try await jobs.completeStage(
                    jobId: job.id, leaseToken: token, stage: .musicalAnalysis, state: state)
                guard let refreshed = try await jobs.job(id: job.id) else { return .idle }
                job = refreshed
                if refreshed.isComplete { return .jobCompleted(jobId: job.id) }

            case .waiting(let reason, let retryAfter):
                try await jobs.markWaiting(
                    jobId: job.id, leaseToken: token, reason: reason, retryAfter: retryAfter)
                return .jobWaiting(jobId: job.id, reason: reason)

            case .transientFailure(let code, let message):
                try await jobs.recordTransientFailure(
                    jobId: job.id, leaseToken: token, errorCode: code, errorMessage: message)
                return .jobFailed(jobId: job.id)
            }
        }
    }

    /// Map a scheduler-level block to the closest persisted job-state
    /// (`waitingForPower`/`waitingForCooling` are the only two of the
    /// plan's fixed state list that fit an ambient policy gate rather than a
    /// worker-reported condition); every other gate (user pause, playback
    /// priority, missing background grant) has no dedicated state and
    /// simply releases the job back to `.queued` (plan §4: no per-track
    /// state churn for these).
    private func releaseOrMarkWaiting(
        jobId: String, leaseToken: String, reason: IndexBlockReason
    ) async throws {
        switch reason {
        case .lowBatteryOrLowPowerMode, .chargingOnlyRequired:
            try await jobs.markWaiting(
                jobId: jobId, leaseToken: leaseToken, reason: .waitingForPower, retryAfter: nil)
        case .thermalFair, .thermalSerious, .thermalCritical, .memoryWarning:
            try await jobs.markWaiting(
                jobId: jobId, leaseToken: leaseToken, reason: .waitingForCooling, retryAfter: nil)
        case .userPaused, .playbackActive, .backgroundGrantMissing:
            try await jobs.releaseToQueued(jobId: jobId, leaseToken: leaseToken)
        }
    }
}
