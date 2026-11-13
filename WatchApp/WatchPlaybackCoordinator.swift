import Foundation
import SwiftUI
import TonearmWatchCore

/// Owns the watch's playback target. Platterhead Watch is intentionally local-only: the phone
/// synchronizes catalog metadata and downloads, while `WatchPlayer` owns all playback.
@MainActor
final class WatchPlaybackCoordinator: ObservableObject {
    static let shared = WatchPlaybackCoordinator()

    @Published private(set) var target: WatchPlaybackTarget

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
        Task { await WatchAppAssembly.shared.diagnostics.record(.playbackTarget, WatchPlaybackTarget.thisWatch.rawValue) }
    }
}
