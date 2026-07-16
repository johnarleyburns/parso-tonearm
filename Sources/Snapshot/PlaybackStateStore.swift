import Foundation

/// The persisted now-playing state: enough to rebuild the play queue (paused, at
/// the saved position) after the app is suspended or relaunched, so playback
/// resumes from the last known queue.
public struct PlaybackStateSnapshot: Codable, Equatable {
    public var trackIDs: [Int64]
    public var currentIndex: Int
    public var elapsed: Double
    public var isPlaying: Bool
    public var savedAt: Date
}

public enum PlaybackStateStore {
    private static let stateKey = "guru.parso.tonearm.playback.state.v1"

    public static func load(defaults: UserDefaults? = sharedDefaults()) -> PlaybackStateSnapshot? {
        guard
            let defaults,
            let data = defaults.data(forKey: stateKey),
            let snapshot = try? JSONDecoder().decode(PlaybackStateSnapshot.self, from: data)
        else {
            return nil
        }
        return snapshot
    }

    public static func save(_ snapshot: PlaybackStateSnapshot, defaults: UserDefaults? = sharedDefaults()) {
        guard
            let defaults,
            let data = try? JSONEncoder().encode(snapshot)
        else {
            return
        }
        defaults.set(data, forKey: stateKey)
    }

    public static func clear(defaults: UserDefaults? = sharedDefaults()) {
        defaults?.removeObject(forKey: stateKey)
    }

    public static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: WidgetSnapshotStore.appGroupIdentifier)
    }
}
