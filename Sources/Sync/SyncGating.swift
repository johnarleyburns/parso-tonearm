import Foundation

/// Pure gating rules for iCloud sync so `SyncGatingTests` can assert the engine
/// only runs under the right conditions without instantiating CloudKit. The
/// engine (`CloudSyncEngine`) consults `shouldRun` before doing any work and
/// `stopReason` on downgrade / toggle-off.
public enum SyncGating {

    /// The persisted opt-in toggle, default **OFF** (privacy stance, C1/C5).
    private static let enabledKey = "sync.icloud.enabled"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// iCloud account availability, mirrors `CKAccountStatus.available`.
    public enum AccountStatus: Equatable {
        case available
        case noAccount
        case restricted
        case couldNotDetermine
        case temporarilyUnavailable
    }

    /// The engine runs when the user opted in and an iCloud account is available.
    /// iCloud sync is free for all users.
    public static func shouldRun(toggleOn: Bool, account: AccountStatus) -> Bool {
        toggleOn && account == .available
    }

    /// Human-facing reason the engine isn't running (nil when it should run).
    public static func inactiveHint(toggleOn: Bool, account: AccountStatus) -> String? {
        if !toggleOn { return "iCloud sync is off." }
        switch account {
        case .available: return nil
        case .noAccount: return "Sign in to iCloud to sync."
        case .restricted: return "iCloud is restricted on this device."
        case .couldNotDetermine, .temporarilyUnavailable:
            return "iCloud is temporarily unavailable."
        }
    }

    /// On toggle-off the engine stops but **never** deletes local
    /// data — mirrors the cache "lazy, never bulk-delete" rule (C5).
    public static func shouldStopButKeepData(toggleOn: Bool) -> Bool {
        !toggleOn
    }
}
