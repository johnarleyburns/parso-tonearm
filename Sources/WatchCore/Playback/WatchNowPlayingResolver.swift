import Foundation

/// Watch redesign §4 — which engine the Home hero and Now Playing show.
///
/// The hero follows *whatever is playing*, on either device, so music started on the iPhone shows up
/// on the watch even when the last explicit target was the watch. This never changes
/// `WatchPlaybackCoordinator.target` (the §7.1 rule that only the user switches targets): it only
/// decides what is on screen, and the shown engine is the one its transport addresses.
public enum WatchNowPlayingResolver {
    public struct Engine: Equatable, Sendable {
        public var hasItem: Bool
        public var isPlaying: Bool

        public init(hasItem: Bool, isPlaying: Bool) {
            self.hasItem = hasItem
            self.isPlaying = isPlaying
        }

        public static let empty = Engine(hasItem: false, isPlaying: false)
    }

    /// Precedence: a playing engine wins (the watch first, since its audio is in the user's ears);
    /// then the explicit target if it has something loaded; then whichever engine has an item.
    public static func shown(local: Engine, remote: Engine, target: WatchPlaybackTarget) -> WatchPlaybackTarget? {
        if local.isPlaying { return .thisWatch }
        if remote.isPlaying { return .iPhone }
        switch target {
        case .thisWatch where local.hasItem: return .thisWatch
        case .iPhone where remote.hasItem: return .iPhone
        default: break
        }
        if local.hasItem { return .thisWatch }
        if remote.hasItem { return .iPhone }
        return nil
    }
}
