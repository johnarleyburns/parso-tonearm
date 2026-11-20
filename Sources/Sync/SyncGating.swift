import Foundation
import TonearmWatchProtocol

/// Pure gating rules for iCloud sync so `SyncGatingTests` can assert the engine
/// only runs under the right conditions without instantiating CloudKit. The
/// engine (`CloudSyncEngine`) consults `shouldRun` before doing any work and
/// `stopReason` on downgrade / toggle-off.
public enum SyncGating {

    /// The persisted opt-in toggle, default **OFF** (privacy stance, C1/C5).
    private static let enabledKey = "sync.icloud.enabled"

    /// Production accessor (the app's standard defaults). Tests pass an
    /// `InMemoryDefaultsStore` to `isEnabled(in:)`/`setEnabled(_:in:)` instead
    /// of mutating the process-wide standard domain.
    public static var isEnabled: Bool {
        get { isEnabled(in: UserDefaults.standard) }
        set { setEnabled(newValue, in: UserDefaults.standard) }
    }

    public static func isEnabled(in defaults: any DefaultsStoring) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    public static func setEnabled(_ enabled: Bool, in defaults: any DefaultsStoring) {
        defaults.set(enabled, forKey: enabledKey)
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
        case .noAccount: return String(localized: "Sign in to iCloud to sync.", bundle: .module)
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
