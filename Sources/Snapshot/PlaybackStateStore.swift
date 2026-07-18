import Foundation

/// The persisted now-playing state: enough to rebuild the play queue (paused, at
/// the saved position) after the app is suspended or relaunched, so playback
/// resumes from the last known queue.
public struct PlaybackStateSnapshot: Codable, Equatable {
    public var trackIDs: [Int64]
    /// Stable cross-device identity for the queued tracks (parallel to `trackIDs`).
    /// Nil when populated from a v1 payload (pre-F1). Filled by F1 persist.
    public var trackSyncIDs: [String?]? = nil
    public var currentIndex: Int
    public var elapsed: Double
    public var isPlaying: Bool
    public var savedAt: Date

    /// Sanitizes elapsed to a finite non-negative value.
    public var sanitizedElapsed: Double {
        elapsed.isFinite ? max(0, elapsed) : 0
    }
}

public enum PlaybackStateStore {
    private static let stateKey = "guru.parso.tonearm.playback.state.v1"

    /// Injectable defaults provider so tests can point the singleton
    /// `AudioPlayer` at an ephemeral suite and spy on writes.
    public static var defaultsProvider: () -> UserDefaults? = { sharedDefaults() }

    public static func load(defaults: UserDefaults? = nil) -> PlaybackStateSnapshot? {
        let explicitDefaults = defaults  // explicitly passed arg
        if explicitDefaults != nil {
            // Explicit suite → only read from that suite (test isolation).
            return loadFromDefaults(defaults)
        }
        // Production path: merge file tier + App Group defaults.
        let file = PlaybackStateFileStore.load()
        let ud = loadFromDefaults(defaults)
        switch (file, ud) {
        case let (f?, u?): return f.savedAt >= u.savedAt ? f : u
        case let (f?, nil): return f
        case let (nil, u?): return u
        case (nil, nil): return nil
        }
    }

    private static func loadFromDefaults(_ defaults: UserDefaults? = nil) -> PlaybackStateSnapshot? {
        let defaults = defaults ?? defaultsProvider()
        guard let defaults,
              let data = defaults.data(forKey: stateKey),
              let snapshot = try? JSONDecoder().decode(PlaybackStateSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    /// Saves to the atomic file tier (primary) and the App Group UserDefaults
    /// (widget back-compat). Elapsed is sanitised to a finite non‑negative value
    /// before encoding (NaN → 0).
    public static func save(_ snapshot: PlaybackStateSnapshot, defaults: UserDefaults? = nil) {
        var snap = snapshot
        snap.elapsed = snap.sanitizedElapsed
        PlaybackStateFileStore.save(snap)
        let defaults = defaults ?? defaultsProvider()
        guard let defaults,
              let data = try? JSONEncoder().encode(snap)
        else { return }
        defaults.set(data, forKey: stateKey)
    }

    public static func clear(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? defaultsProvider()
        defaults?.removeObject(forKey: stateKey)
        // Also remove the file tier entry so stale data isn't resurrected.
        if let url = PlaybackStateFileStore.fileURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: WidgetSnapshotStore.appGroupIdentifier)
    }
}
