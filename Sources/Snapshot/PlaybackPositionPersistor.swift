import Foundation

/// Composite store owned by `AudioPlayer` that funnels every persistence write
/// through the admission policy and distributes to the file, defaults, and
/// (optionally) cloud tiers. The only public operations are `save` and
/// `loadBest`; the policy + throttles live inside `save`.
@MainActor
public final class PlaybackPositionPersistor {
    /// Throttle for cloud pushes while playing: at most one push per 30 s.
    public static let cloudPushInterval: TimeInterval = 30

    public var cloudBackend: PlaybackCloudBackend?
    /// File + defaults tiers. Injectable so tests can use an in-memory store
    /// instead of the process-wide App Group file/domain.
    let stateStore: any PlaybackStatePersistence

    private(set) var lastPersistAt: Date = .distantPast
    private(set) var lastCloudPushAt: Date = .distantPast

    public init(cloudBackend: PlaybackCloudBackend? = nil,
                stateStore: any PlaybackStatePersistence = CompositePlaybackStatePersistence()) {
        self.cloudBackend = cloudBackend
        self.stateStore = stateStore
    }

    /// Saves `candidate` (nil means "clear") after admission, then distributes
    /// to the file + defaults tiers. If a cloud backend is set, enqueues a
    /// cloud push throttled to `cloudPushInterval` (+ fires on every discrete
    /// event regardless of the interval).
    public func save(
        candidate: PlaybackStateSnapshot?,
        reason: PlaybackWriteReason
    ) {
        let existing = stateStore.load()
        guard PlaybackWritePolicy.admits(candidate: candidate, existing: existing, reason: reason) else {
            return
        }

        if let candidate {
            stateStore.save(candidate)
        } else {
            stateStore.clear()
        }

        lastPersistAt = Date()

        // Cloud push: fire on every discrete event or throttled during playback.
        if let backend = cloudBackend, let snap = candidate {
            let now = Date()
            let isDiscrete: Bool
            switch reason {
            case .tick:           isDiscrete = false
            case .transportEvent, .userSeek, .queueChange,
                 .restoreCommit, .background, .userClear:
                isDiscrete = true
            }
            if isDiscrete || now.timeIntervalSince(lastCloudPushAt) >= Self.cloudPushInterval {
                lastCloudPushAt = now
                backend.save(snap)
            }
        }
    }

    /// Returns the best available snapshot from the composite store (file →
    /// defaults → cloud, max-by-savedAt).
    public func loadBest() async -> PlaybackStateSnapshot? {
        // Production path (no cloud) or cloud attached.
        let local = stateStore.load()
        if let backend = cloudBackend, let remote = await backend.load() {
            if let loc = local {
                return loc.savedAt >= remote.savedAt ? loc : remote
            }
            return remote
        }
        return local
    }
}
