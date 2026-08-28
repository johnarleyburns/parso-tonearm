import Foundation
import SwiftUI
import TonearmWatchCore

/// Owns the one piece of state §7.1 insists is always explicit and always visible: which engine —
/// `iPhone` or `thisWatch` — transport is addressed to. Changing it is only ever a user action;
/// nothing here switches targets automatically. Also arms the §7.5 "Continue on Apple Watch"
/// offer when the phone drops while it was the target.
@MainActor
final class WatchPlaybackCoordinator: ObservableObject {
    static let shared = WatchPlaybackCoordinator()

    @Published private(set) var target: WatchPlaybackTarget
    /// Non-nil when the phone became unreachable mid-playback and its current track is downloaded
    /// here — the W7 view shows the explicit "Continue on Apple Watch" / "Keep Waiting" card.
    @Published private(set) var continuePrompt: WatchContinueOnWatchPlan?

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
        continuePrompt = nil
        let code = target.rawValue
        Task { await WatchAppAssembly.shared.diagnostics.record(.playbackTarget, code) }
        if target == .iPhone {
            // Coming back to the phone: drop any stale local prediction so the W7 view shows a
            // fresh "updating…" rather than a frozen old clock until the next snapshot lands.
            WatchRemotePlayer.shared.clear()
        }
    }

    // MARK: - Continue on Apple Watch (§7.5)

    /// The phone link was confirmed down. If it was the target and its last known track is
    /// downloaded here, arm the explicit continuation offer. Never switches targets or starts
    /// playback on its own; never sends a speculative stop to the unreachable phone.
    func armContinueFromDisconnect() {
        guard target == .iPhone, continuePrompt == nil,
              let snapshot = WatchRemotePlayer.shared.state?.snapshot else { return }
        Task {
            let available = await WatchAppAssembly.shared.locallyAvailableTrackIDs()
            guard let plan = WatchContinueOnWatchPlan.make(from: snapshot, locallyAvailable: available)
            else { return }
            self.continuePrompt = plan
        }
    }

    /// The link is back — the offer is moot.
    func clearContinueOnReconnect() { continuePrompt = nil }

    /// "Continue on Apple Watch" — start the local queue at the last anchor and switch the target.
    func acceptContinue() {
        guard let plan = continuePrompt else { return }
        continuePrompt = nil
        Task { await WatchAppAssembly.shared.startContinueOnWatch(plan) }
    }

    /// "Keep Waiting".
    func dismissContinue() { continuePrompt = nil }
}
