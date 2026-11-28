import Foundation
import TonearmCore

/// One bounded unit of outcome for a claimed job. `IndexScheduler` drives a
/// job to completion by calling `processNextUnit`, checking policy between
/// calls.
///
/// The real implementation (windowed reader + LeanAnalysis) lives in
/// `BoundedIndexWorker`. This protocol is the seam: `IndexScheduler` is
/// fully testable against a synthetic in-memory worker.
public protocol IndexJobExecuting: Sendable {
    /// Perform the job's one bounded unit of work (the musical-analysis
    /// pass) for `job`, using `leaseToken` if the implementation persists
    /// anything itself. Must not block longer than a single bounded unit —
    /// no whole-file decode (plan §6).
    func processNextUnit(job: DiscoveryIndexJob, leaseToken: String) async -> IndexWorkOutcome
}

/// Also usable as a thrown sentinel by `BoundedIndexWorker`'s internal
/// helpers (e.g. a duration-read failure classified as terminal vs.
/// transient) so that classification logic lives in one place.
public enum IndexWorkOutcome: Error, Equatable, Sendable {
    /// The musical-analysis stage reached a terminal state.
    case musicalAnalysisStageFinished(DiscoveryStageState)
    /// Could not make progress for a non-transient reason.
    case waiting(reason: DiscoveryJobState, retryAfterSeconds: TimeInterval?)
    /// A transient failure (decode error, read error). Consumes one retry
    /// attempt (plan §11).
    case transientFailure(code: String, message: String?)
}
