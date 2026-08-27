import Foundation
import TonearmWatchProtocol

/// Pure scheduling policy for the phone transfer manager (§8.2).
///
/// - Maximum two outstanding audio file transfers and one metadata/artwork transfer.
/// - Priority order from §8.1, then FIFO by creation.
/// - `failed` jobs re-enter only after `nextAttemptAt`; the manager sets that using `backoff`.
/// - Transient failures back off and retry; auth/source/file failures never spin.
public enum PhoneWatchTransferScheduler {
    public static let maxAudioInFlight = 2
    public static let maxMetadataInFlight = 1

    /// Bounded exponential backoff. Attempt 1 → base, doubling, capped.
    public static func backoff(attempt: Int, base: TimeInterval = 5,
                               cap: TimeInterval = 300) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let raw = base * pow(2, Double(attempt - 1))
        return min(raw, cap)
    }

    /// Maps a §5.5 error code to a retry class, deriving it from the code's own
    /// `retryPolicy` so there is one source of truth. A missing code (a bare transport error)
    /// is transient — a network fault must never become a permanent skip by omission.
    public static func classify(_ code: WatchProtocolErrorCode?) -> PhoneWatchFailureClass {
        guard let code else { return .transient }
        switch code.retryPolicy {
        case .boundedSchedulerRetry, .automaticWhenPolicyPermits, .singleUserRetry,
             .userRetryAfterReconnect, .freeSpaceThenRetry:
            return .transient
        case .externalActionRequired, .userConfirmationRequired:
            return code == .authenticationRequired ? .needsAuth : .sourceUnavailable
        case .permanentForContent, .refreshWithoutRetry, .appUpgradeRequired, .informationalOnly:
            return .fileUnsupported
        }
    }

    /// Which request IDs to hand to the transfer seam next, given the full job set and the wall
    /// clock. Never exceeds the in-flight caps; never returns a job gated by `nextAttemptAt`.
    public static func nextDispatch(jobs: [PhoneWatchDownloadJob],
                                    now: Date,
                                    canTransferOnNetwork: Bool) -> [String] {
        let audioInFlight = jobs.filter { $0.state == .transferring || $0.state == .resolving }.count
        var audioSlots = max(0, maxAudioInFlight - audioInFlight)
        guard audioSlots > 0, canTransferOnNetwork else { return [] }

        let ready = jobs
            .filter { job in
                switch job.state {
                case .queued, .waitingForWiFi:
                    if let at = job.nextAttemptAt, at > now { return false }
                    return true
                default:
                    return false
                }
            }
            .sorted { a, b in
                if a.priority != b.priority { return a.priority < b.priority }
                return a.createdAt < b.createdAt
            }

        var picked: [String] = []
        for job in ready where audioSlots > 0 {
            picked.append(job.requestID)
            audioSlots -= 1
        }
        return picked
    }
}
