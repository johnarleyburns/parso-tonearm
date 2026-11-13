import Foundation
import TonearmWatchProtocol

/// Pure mapping from connection/sync state to Home's single-line status chip (watch redesign §3's
/// StatusChip — built as `WatchStatusChip`, an App-layer view, but never wired into Home; the
/// connection/sync banner lived instead as a full-width, multi-line `Section` at the very top of
/// the list). Kept here, pure, so it is testable without a simulator — the
/// `WatchScrubPolicy`/`QueueFailureRecoveryPolicy` pattern elsewhere in this codebase.
public enum WatchHomeStatusPolicy {
    public enum Tone: Equatable, Sendable { case good, warning, failure }

    public struct Status: Equatable, Sendable {
        public let title: String
        public let tone: Tone
        public init(title: String, tone: Tone) {
            self.title = title
            self.tone = tone
        }
    }

    /// `banner` is `WatchConnectionChrome`'s own live-reachability state — the truth for whether
    /// the phone is actually reachable right now. `isSyncing`/`syncResult` are
    /// `WatchSyncStatusState`'s separate metadata-sync receipt (its own doc comment: background
    /// packets can update sync history even while live reachability disagrees), so a live banner
    /// of `.unavailable`/`.incompatible` always wins over a stale syncing flag or past result. A
    /// sync failure while still connected is a warning, not a failure — the link itself is fine.
    public static func status(banner: WatchConnectionChrome.Banner, isSyncing: Bool,
                              syncResult: WatchMetadataSyncResult?) -> Status {
        switch banner {
        case .incompatible:
            return Status(title: String(localized: "Update Platterhead on iPhone"), tone: .failure)
        case .unavailable:
            return Status(title: String(localized: "iPhone not connected"), tone: .failure)
        case .temporarilyUnavailable:
            return Status(title: String(localized: "iPhone connection blip…"), tone: .warning)
        case .connected:
            if isSyncing {
                return Status(title: String(localized: "Syncing with iPhone…"), tone: .good)
            }
            if let syncResult, case .failed = syncResult {
                return Status(title: syncResult.displayMessage, tone: .warning)
            }
            return Status(title: String(localized: "iPhone connected"), tone: .good)
        }
    }
}
