import Foundation
import TonearmWatchProtocol

/// The phone's `AudioPlayer`, as the §5 protocol needs to see it.
///
/// §1.2: connected playback *is* remote playback — a `playCommand` runs on the phone's existing
/// player and the watch is a remote control. This is the seam that keeps that testable: the real
/// adapter (`Sources/App/Watch/PhoneWatchPlaybackAdapter`) drives `AudioPlayer` on the main actor;
/// a spy in `swift test` records the directives and returns a scripted snapshot, so the Phase 4
/// definition of done — "play a playlist through a spy phone player" — needs no simulator.
///
/// Every mutator is fire-and-forget from the protocol's point of view: the authoritative result is
/// always read back with `snapshot(revision:)` and returned to the watch in the `commandReply`
/// (§7.1's elapsed anchor + queue window).
public protocol PhoneWatchPlaybackBridge: Sendable {
    /// The phone's current now-playing state, as an anchor + rate (§5.3).
    func snapshot(revision: Int64) async -> WatchPhonePlaybackSnapshot

    /// Replace the queue and begin playback. `collection` is the crate the rows came from, carried
    /// only so Now Playing can name it; the phone never re-resolves it.
    func play(_ tracks: [TrackRow], startIndex: Int,
              collection: WatchCollectionRef?, collectionTitle: String?) async

    func setPlaying(_ playing: Bool) async
    func togglePlayPause() async
    /// `+1` → next, `-1` → previous. §7.3's "previous at elapsed < 3 s restarts the track" is the
    /// player's own rule and is not re-implemented here.
    func advance(by offset: Int) async
    func jump(toIndex index: Int) async
    func seek(toSeconds seconds: Double) async
    func setShuffle(_ enabled: Bool) async
    func setRepeat(_ mode: TonearmWatchProtocol.WatchRepeatMode) async
}

/// Builds a `WatchPhonePlaybackSnapshot` from primitive now-playing values. Pure and
/// host-tested; the real adapter's only job is to gather `AudioPlayer`'s published state and call
/// this. Keeping the window math here means the "never the whole queue" rule (§5.3) has exactly one
/// implementation.
public enum WatchPlaybackSnapshotBuilder {
    public struct Input: Sendable {
        public var revision: Int64
        public var source: WatchPlaybackSourceKind
        public var isPlaying: Bool
        public var queue: [WatchTrackSummary]
        public var index: Int
        public var elapsedSeconds: Double
        public var anchorDate: Date
        public var collection: WatchCollectionRef?
        public var collectionTitle: String?
        public var shuffleEnabled: Bool
        public var repeatMode: TonearmWatchProtocol.WatchRepeatMode

        public init(revision: Int64,
                    source: WatchPlaybackSourceKind,
                    isPlaying: Bool,
                    queue: [WatchTrackSummary],
                    index: Int,
                    elapsedSeconds: Double,
                    anchorDate: Date = Date(),
                    collection: WatchCollectionRef? = nil,
                    collectionTitle: String? = nil,
                    shuffleEnabled: Bool = false,
                    repeatMode: TonearmWatchProtocol.WatchRepeatMode = .off) {
            self.revision = revision
            self.source = source
            self.isPlaying = isPlaying
            self.queue = queue
            self.index = index
            self.elapsedSeconds = elapsedSeconds
            self.anchorDate = anchorDate
            self.collection = collection
            self.collectionTitle = collectionTitle
            self.shuffleEnabled = shuffleEnabled
            self.repeatMode = repeatMode
        }
    }

    public static func build(_ input: Input) -> WatchPhonePlaybackSnapshot {
        let count = input.queue.count
        guard count > 0 else {
            return WatchPhonePlaybackSnapshot(
                revision: input.revision, source: .none, isPlaying: false, rate: 0,
                elapsedAnchorDate: input.anchorDate,
                shuffleEnabled: input.shuffleEnabled, repeatMode: input.repeatMode)
        }

        let index = min(max(0, input.index), count - 1)
        let limit = WatchPhonePlaybackSnapshot.queueWindowLimit
        // A window centred on the current item, clamped to the queue's ends so the count is stable
        // near the boundaries.
        let half = limit / 2
        var start = index - half
        if start < 0 { start = 0 }
        if start + limit > count { start = max(0, count - limit) }
        let end = min(start + limit, count)
        let window = Array(input.queue[start..<end])

        return WatchPhonePlaybackSnapshot(
            revision: input.revision,
            source: input.source,
            isPlaying: input.isPlaying,
            rate: input.isPlaying ? 1 : 0,
            currentItem: input.queue[index],
            collection: input.collection,
            collectionTitle: input.collectionTitle,
            queueWindow: window,
            queueWindowStartIndex: start,
            queueIndex: index,
            queueCount: count,
            elapsedSeconds: max(0, input.elapsedSeconds),
            elapsedAnchorDate: input.anchorDate,
            shuffleEnabled: input.shuffleEnabled,
            repeatMode: input.repeatMode)
    }
}
