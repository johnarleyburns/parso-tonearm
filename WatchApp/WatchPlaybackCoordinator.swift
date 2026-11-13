import Foundation
import SwiftUI
import TonearmWatchCore

/// Owns the watch's playback target. Platterhead Watch is intentionally local-only: the phone
/// synchronizes catalog metadata and downloads, while `WatchPlayer` owns all playback.
@MainActor
final class WatchPlaybackCoordinator: ObservableObject {
    static let shared = WatchPlaybackCoordinator()

    let target: WatchPlaybackTarget = .thisWatch
}
