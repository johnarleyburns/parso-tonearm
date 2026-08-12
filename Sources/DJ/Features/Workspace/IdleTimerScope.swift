import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Idle-timer scoping (§34A.6, plan §2.14): the screen never auto-locks while
/// any deck plays and the system idle timer is restored the instant both stop.
/// The scoping lives in the session view model — engine-adjacent, never in a
/// view's lifetime — and is driven from published telemetry, not from
/// `onAppear`/`onDisappear`.
///
/// macOS has no UIKit idle timer; on this host the scoping is a no-op so the
/// SPM package still builds for the `swift test` host.
@MainActor
public enum IdleTimerScope {

    /// Apply the scoping for the current play state.
    public static func update(anyDeckPlaying: Bool) {
        #if canImport(UIKit)
        let application = UIApplication.shared
        if application.isIdleTimerDisabled != anyDeckPlaying {
            application.isIdleTimerDisabled = anyDeckPlaying
        }
        #endif
    }
}
