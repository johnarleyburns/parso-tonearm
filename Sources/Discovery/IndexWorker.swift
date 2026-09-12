import Foundation
import TonearmCore

/// One bounded unit of outcome for a claimed job. `IndexScheduler` drives a
/// job to completion by calling `processNextUnit` repeatedly, checking
/// policy between calls (plan §6: "Cancellation is checked before/after each
/// window").
///
/// The real implementation (windowed reader + ModelManager + CLAP encoder +
/// BPM/key analyzer) is plan C04, not built this session. This protocol is
/// the seam: `IndexScheduler` is fully testable now against a synthetic
/// in-memory worker, and the C04 windowed-reader/model implementation can
/// conform to this same protocol later without changing the scheduler.
public protocol IndexJobExecuting: Sendable {
    /// Perform exactly one bounded unit of work (one audio window, or one
    /// musical-analysis pass) for `job`, using `leaseToken` to guard any
    /// persistence the implementation performs itself (e.g. via
    /// `IndexJobRepository.recordWindowCompletion`). Must not block longer
    /// than a single bounded unit — no whole-file decode (plan §6).
    func processNextUnit(job: DiscoveryIndexJob, leaseToken: String) async -> IndexWorkOutcome
}

/// Also usable as a thrown sentinel by `BoundedIndexWorker`'s internal
/// helpers (e.g. a duration-read failure classified as terminal vs.
/// transient) so that classification logic lives in one place.
public enum IndexWorkOutcome: Error, Equatable, Sendable {
    /// One more window embedded and checkpointed; more remain.
    case windowCompleted
    /// The embedding stage reached a terminal state (all windows pooled,
    /// quantized and committed, or it failed/is unsupported for this asset).
    case embeddingStageFinished(DiscoveryStageState)
    /// The musical-analysis stage reached a terminal state.
    case musicalAnalysisStageFinished(DiscoveryStageState)
    /// Could not make progress for a non-transient reason.
    case waiting(reason: DiscoveryJobState, retryAfterSeconds: TimeInterval?)
    /// A transient failure (decode error, transient model error). Consumes
    /// one retry attempt (plan §11).
    case transientFailure(code: String, message: String?)
}
