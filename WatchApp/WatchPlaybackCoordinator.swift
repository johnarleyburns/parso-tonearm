import Foundation
import SwiftUI
import TonearmWatchCore

/// Owns the one piece of state §7.1 insists is always explicit and always visible: which engine —
/// `iPhone` or `thisWatch` — transport is addressed to. Changing it is only ever a user action;
/// nothing here switches targets automatically.
@MainActor
final class WatchPlaybackCoordinator: ObservableObject {
    static let shared = WatchPlaybackCoordinator()

    @Published private(set) var target: WatchPlaybackTarget

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        self.target = WatchPlaybackTargetStore.load(defaults: defaults)
    }

    /// The explicit user switch. Persisted so the next launch defaults to the last explicit choice.
    func setTarget(_ target: WatchPlaybackTarget) {
        guard target != self.target else { return }
        self.target = target
        WatchPlaybackTargetStore.save(target, defaults: defaults)
        if target == .iPhone {
            // Coming back to the phone: drop any stale local prediction so the W7 view shows a
            // fresh "updating…" rather than a frozen old clock until the next snapshot lands.
            WatchRemotePlayer.shared.clear()
        }
    }
}
