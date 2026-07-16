import Foundation

/// The persisted now-playing state: enough to rebuild the play queue (paused, at
/// the saved position) after the app is suspended or relaunched, so Live Activity
/// intent buttons always have a player to act on (Fix 2).
struct PlaybackStateSnapshot: Codable, Equatable {
    var trackIDs: [Int64]
    var currentIndex: Int
    var elapsed: Double
    var isPlaying: Bool
    var savedAt: Date
}

enum PlaybackStateStore {
    private static let stateKey = "guru.parso.tonearm.playback.state.v1"

    static func load(defaults: UserDefaults? = sharedDefaults()) -> PlaybackStateSnapshot? {
        guard
            let defaults,
            let data = defaults.data(forKey: stateKey),
            let snapshot = try? JSONDecoder().decode(PlaybackStateSnapshot.self, from: data)
        else {
            return nil
        }
        return snapshot
    }

    static func save(_ snapshot: PlaybackStateSnapshot, defaults: UserDefaults? = sharedDefaults()) {
        guard
            let defaults,
            let data = try? JSONEncoder().encode(snapshot)
        else {
            return
        }
        defaults.set(data, forKey: stateKey)
    }

    static func clear(defaults: UserDefaults? = sharedDefaults()) {
        defaults?.removeObject(forKey: stateKey)
    }

    private static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: WidgetSnapshotStore.appGroupIdentifier)
    }
}
