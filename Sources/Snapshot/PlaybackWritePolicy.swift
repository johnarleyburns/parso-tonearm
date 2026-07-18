import Foundation

public enum PlaybackWriteReason {
    /// Periodic 0.5 s tick while advancing (throttled to ≥ 1 write/s).
    case tick
    /// Discrete transport event: play, pause, track change, interruption, route change.
    case transportEvent
    /// Explicit user seek.
    case userSeek
    /// Queue structure changed (reorder, insert, remove, shuffle).
    case queueChange
    /// Restore finalisation after seek confirmed.
    case restoreCommit
    /// App backgrounding / inactivity flush.
    case background
    /// Explicit user action emptying the queue.
    case userClear
}

/// Pure write-admission policy implementing guarantees G3 (no regression) and
/// G4 (no spurious erasure). All snapshot saves route through this policy.
public enum PlaybackWritePolicy {

    /// Returns `true` when `candidate` (nil means "clear") should be admitted
    /// given the `existing` durable snapshot and the `reason` for the write.
    public static func admits(
        candidate: PlaybackStateSnapshot?,
        existing: PlaybackStateSnapshot?,
        reason: PlaybackWriteReason
    ) -> Bool {
        // G4: clear is admitted ONLY for explicit user-clear.
        guard let candidate else {
            return reason == .userClear
        }

        guard let existing else {
            // First write: always admit.
            return true
        }

        // Different queue or different index → always admit.
        if candidate.trackIDs != existing.trackIDs || candidate.currentIndex != existing.currentIndex {
            return true
        }

        // Same queue & index: regression check.
        // A candidate that moves elapsed backwards by > 1.0 s is admitted only
        // for reasons that represent an explicit user/transport action.
        let regression = existing.elapsed - candidate.elapsed
        if regression > 1.0 {
            switch reason {
            case .userSeek, .transportEvent, .queueChange, .restoreCommit:
                return true
            case .tick, .background, .userClear:
                return false  // G3: tick/background may never regress
            }
        }

        return true
    }
}
