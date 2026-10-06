import Foundation
import SwiftUI
import TonearmWatchCore

/// Owns the watch's playback target. Platterhead Watch is intentionally local-only: the phone
/// synchronizes catalog metadata and downloads, while `WatchPlayer` owns all playback.
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
        self.target = .thisWatch
    }

    /// The explicit user switch. Persisted so the next launch defaults to the last explicit choice.
    func setTarget(_ target: WatchPlaybackTarget) {
        guard target == .thisWatch, self.target != .thisWatch else { return }
        self.target = .thisWatch
        WatchPlaybackTargetStore.save(.thisWatch, defaults: defaults)
        continuePrompt = nil
        Task { await WatchAppAssembly.shared.diagnostics.record(.playbackTarget, WatchPlaybackTarget.thisWatch.rawValue) }
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
