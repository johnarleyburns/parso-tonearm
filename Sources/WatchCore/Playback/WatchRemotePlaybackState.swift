import Foundation
import TonearmWatchProtocol

/// The watch's view of what the *phone* is playing (§7.1 iPhone target). Wraps the last
/// `WatchPhonePlaybackSnapshot` together with the instant it arrived, so the UI can predict the
/// elapsed clock forward from the anchor and show how stale the picture is.
///
/// Pure and host-tested — `WatchRemotePlayer` (`@MainActor`) is the only thing that holds one.
public struct WatchRemotePlaybackState: Equatable, Sendable {
    public let snapshot: WatchPhonePlaybackSnapshot
    /// When this snapshot was received on the watch (not the phone's anchor date).
    public let receivedAt: Date

    public init(snapshot: WatchPhonePlaybackSnapshot, receivedAt: Date) {
        self.snapshot = snapshot
        self.receivedAt = receivedAt
    }

    /// Fold in a freshly-received snapshot, or `nil` when it is older than what is already held —
    /// a late `commandReply` or a re-ordered context must never roll the picture backwards
    /// (I-06 revision ordering).
    public func applying(_ newer: WatchPhonePlaybackSnapshot, at date: Date) -> WatchRemotePlaybackState? {
        guard newer.revision >= snapshot.revision else { return nil }
        return WatchRemotePlaybackState(snapshot: newer, receivedAt: date)
    }

    // MARK: - Prediction

    /// Elapsed position projected forward from the phone's anchor, clamped to the track duration.
    public func predictedElapsed(at date: Date) -> Double {
        snapshot.elapsedSeconds(at: date)
    }

    /// Seconds until the current track ends, from the predicted position. `nil` when there is no
    /// known duration.
    public func predictedRemaining(at date: Date) -> Double? {
        guard let duration = snapshot.currentItem?.durationSeconds, duration > 0 else { return nil }
        return max(0, duration - predictedElapsed(at: date))
    }

    // MARK: - Staleness

    public func staleness(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(receivedAt))
    }

    /// Default threshold: three refresh cycles of the W7 correction poll (5 s each).
    public func isStale(at date: Date, threshold: TimeInterval = 15) -> Bool {
        staleness(at: date) >= threshold
    }

    // MARK: - Passthroughs

    public var isPlaying: Bool { snapshot.isPlaying }
    public var currentItem: WatchTrackSummary? { snapshot.currentItem }
    public var queueWindow: [WatchTrackSummary] { snapshot.queueWindow }
    public var queueWindowStartIndex: Int { snapshot.queueWindowStartIndex }
    public var queueIndex: Int { snapshot.queueIndex }
    public var queueCount: Int { snapshot.queueCount }
    public var collectionTitle: String? { snapshot.collectionTitle }
    public var hasQueue: Bool { snapshot.queueCount > 0 }
}
