import Foundation
import TonearmWatchProtocol

/// The persisted now-playing state: enough to rebuild the play queue (paused, at
/// the saved position) after the app is suspended or relaunched, so playback
/// resumes from the last known queue.
public struct PlaybackStateSnapshot: Codable, Equatable, Sendable {
    public var trackIDs: [Int64]
    /// Stable cross-device identity for the queued tracks (parallel to `trackIDs`).
    /// Nil when populated from a v1 payload (pre-F1). Filled by F1 persist.
    public var trackSyncIDs: [String?]? = nil
    public var currentIndex: Int
    public var elapsed: Double
    public var isPlaying: Bool
    public var savedAt: Date
    /// Keep Playing provenance per queued occurrence (parallel to `trackIDs`); nil entries are
    /// non-auto-added. Absent in older payloads.
    public var keepPlayingProvenance: [KeepPlayingProvenance?]? = nil

    /// Sanitizes elapsed to a finite non-negative value.
    public var sanitizedElapsed: Double {
        elapsed.isFinite ? max(0, elapsed) : 0
    }
}

public enum PlaybackStateStore {
    static let stateKey = "guru.parso.tonearm.playback.state.v1"

    /// Injectable defaults provider for the production (no-explicit-store)
    /// path. Tests do not touch this: they inject a `PlaybackStatePersistence`
    /// into the player's `persistor` instead, so no process-wide state leaks
    /// between concurrently running tests.
    private static let defaultsProviderState = LockedValue<() -> (any DefaultsStoring)?>({ sharedDefaults() })
    public static var defaultsProvider: () -> (any DefaultsStoring)? {
        get { defaultsProviderState.read() }
        set { defaultsProviderState.write(newValue) }
    }

    /// Loads a snapshot.
    ///
    /// With an explicit store this is a pure read of that store (tests); with
    /// no store it takes the production path, merging the file tier and the
    /// App Group defaults and keeping whichever is newer.
    public static func load(defaults: (any DefaultsStoring)? = nil) -> PlaybackStateSnapshot? {
        if let defaults {
            return decode(from: defaults)
        }
        let file = PlaybackStateFileStore.load()
        let ud = decode(from: defaultsProvider())
        switch (file, ud) {
        case let (f?, u?): return f.savedAt >= u.savedAt ? f : u
        case let (f?, nil): return f
        case let (nil, u?): return u
        case (nil, nil): return nil
        }
    }

    static func decode(from defaults: (any DefaultsStoring)?) -> PlaybackStateSnapshot? {
        guard let defaults,
              let data = defaults.data(forKey: stateKey),
              let snapshot = try? JSONDecoder().decode(PlaybackStateSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    /// Saves a snapshot. With an explicit store only that store is touched;
    /// otherwise the production file tier and App Group defaults are written.
    /// Elapsed is sanitised to a finite non-negative value before encoding
    /// (NaN → 0).
    public static func save(_ snapshot: PlaybackStateSnapshot, defaults: (any DefaultsStoring)? = nil) {
        var snap = snapshot
        snap.elapsed = snap.sanitizedElapsed

        if let defaults {
            encode(snap, into: defaults)
            return
        }

        PlaybackStateFileStore.save(snap)
        encode(snap, into: defaultsProvider())
    }

    private static func encode(_ snapshot: PlaybackStateSnapshot, into defaults: (any DefaultsStoring)?) {
        guard let defaults,
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        defaults.set(data, forKey: stateKey)
    }

    public static func clear(defaults: (any DefaultsStoring)? = nil) {
        if let defaults {
            defaults.removeObject(forKey: stateKey)
            return
        }
        defaultsProvider()?.removeObject(forKey: stateKey)
        // Also remove the file tier entry so stale data isn't resurrected.
        PlaybackStateFileStore.remove(at: PlaybackStateFileStore.fileURL())
    }

    public static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: WidgetSnapshotStore.appGroupIdentifier)
    }
}

/// The load/save/clear surface `AudioPlayer`'s persistence funnel uses.
///
/// Production composes the atomic file tier with the App Group defaults.
/// Tests inject an in-memory implementation so a suite never shares the real
/// file or preferences domain with another suite running in parallel.
@MainActor
public protocol PlaybackStatePersistence: AnyObject {
    func load() -> PlaybackStateSnapshot?
    func save(_ snapshot: PlaybackStateSnapshot)
    func clear()
}

/// The production composite: file tier plus App Group defaults, selecting the
/// newer snapshot by `savedAt`.
@MainActor
public final class CompositePlaybackStatePersistence: PlaybackStatePersistence {
    private let defaults: (any DefaultsStoring)?
    private let fileURL: URL?

    public init(defaults: (any DefaultsStoring)? = PlaybackStateStore.sharedDefaults(),
                fileURL: URL? = PlaybackStateFileStore.fileURL()) {
        self.defaults = defaults
        self.fileURL = fileURL
    }

    public func load() -> PlaybackStateSnapshot? {
        let file = PlaybackStateFileStore.load(from: fileURL)
        let ud = PlaybackStateStore.decode(from: defaults)
        switch (file, ud) {
        case let (f?, u?): return f.savedAt >= u.savedAt ? f : u
        case let (f?, nil): return f
        case let (nil, u?): return u
        case (nil, nil): return nil
        }
    }

    public func save(_ snapshot: PlaybackStateSnapshot) {
        var snap = snapshot
        snap.elapsed = snap.sanitizedElapsed
        PlaybackStateFileStore.save(snap, to: fileURL)
        if let defaults, let data = try? JSONEncoder().encode(snap) {
            defaults.set(data, forKey: PlaybackStateStore.stateKey)
        }
    }

    public func clear() {
        defaults?.removeObject(forKey: PlaybackStateStore.stateKey)
        PlaybackStateFileStore.remove(at: fileURL)
    }
}
