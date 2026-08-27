import Foundation

/// Which engine owns transport right now (§7.1). Always explicit, always visible on Now Playing —
/// never inferred, never switched automatically.
public enum WatchPlaybackTarget: String, Codable, Sendable, CaseIterable {
    /// The phone's `AudioPlayer`. The watch is a remote control and predicts elapsed from the
    /// last snapshot's `(elapsed, anchorDate, rate)`.
    case iPhone
    /// This watch's local `AVPlayer`, driving a queue of ready local assets.
    case thisWatch

    public var other: WatchPlaybackTarget { self == .iPhone ? .thisWatch : .iPhone }
}

/// Persists the last *explicit* target. §7.1 / plan §4: "connected playback target defaults to the
/// last explicit target, initially iPhone." Same UserDefaults shape as `WatchPositionStore`.
public enum WatchPlaybackTargetStore {
    private static let key = "guru.parso.tonearm.watch.playback.target"

    public static func save(_ target: WatchPlaybackTarget, defaults: UserDefaults? = nil) {
        (defaults ?? .standard).set(target.rawValue, forKey: key)
    }

    /// The stored target, or `.iPhone` when nothing is stored or the value is unrecognised.
    public static func load(defaults: UserDefaults? = nil) -> WatchPlaybackTarget {
        let ud = defaults ?? .standard
        guard let raw = ud.string(forKey: key), let target = WatchPlaybackTarget(rawValue: raw) else {
            return .iPhone
        }
        return target
    }

    public static func clear(defaults: UserDefaults? = nil) {
        (defaults ?? .standard).removeObject(forKey: key)
    }
}
