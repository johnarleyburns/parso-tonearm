#if !os(watchOS)
import Foundation
import TonearmCore
import TonearmWatchProtocol

/// Binds the §5 playback bridge to the phone's real `AudioPlayer`.
///
/// §1.2: connected playback *is* the phone playing, with the watch as a remote. So every method
/// here is a thin forward to `AudioPlayer` on the main actor, and the authoritative answer is always
/// read back from the player's published state through `WatchPlaybackSnapshotBuilder` — the watch
/// never trusts the command's optimistic view of what happened.
///
/// Unwired, like `PhoneWatchProtocolAdapter`: Phase 6 constructs it from `AppState` and hands it to
/// the coordinator. Kept in `Sources/App/Watch` because it touches `AudioPlayer`, which is compiled
/// only by the Xcode target; it holds no protocol logic and no `[String: Any]`.
@MainActor
public final class PhoneWatchPlaybackAdapter: PhoneWatchPlaybackBridge {
    private let player: AudioPlayer
    private let downloadedProvider: @Sendable () async -> Set<WatchTrackID>
    private let artworkBindingProvider: @Sendable (String) async -> (coverArtworkID: String?, customArtworkID: String?)

    public init(player: AudioPlayer,
                downloadedProvider: @escaping @Sendable () async -> Set<WatchTrackID> = { [] },
                artworkBindingProvider: @escaping @Sendable (String) async -> (coverArtworkID: String?, customArtworkID: String?) = { _ in (nil, nil) }) {
        self.player = player
        self.downloadedProvider = downloadedProvider
        self.artworkBindingProvider = artworkBindingProvider
    }

    public func snapshot(revision: Int64) async -> WatchPhonePlaybackSnapshot {
        let downloaded = await downloadedProvider()
        var queue: [WatchTrackSummary] = []
        for row in player.queue {
            let binding = await artworkBindingProvider(PhoneWatchID.track(row.track).rawValue)
            queue.append(PhoneWatchProjection.trackSummary(from: row, downloadedOnWatch: downloaded,
                                                           coverArtworkID: binding.coverArtworkID,
                                                           customArtworkID: binding.customArtworkID))
        }
        let input = WatchPlaybackSnapshotBuilder.Input(
            revision: revision,
            source: queue.isEmpty ? .none : .localLibrary,
            isPlaying: player.isPlaying,
            queue: queue,
            index: player.index,
            elapsedSeconds: player.currentTime,
            anchorDate: Date(),
            collection: collectionRef(for: player.queueSource),
            collectionTitle: collectionTitle(for: player.queueSource),
            shuffleEnabled: player.shuffle,
            repeatMode: Self.watchRepeat(player.repeatMode))
        return WatchPlaybackSnapshotBuilder.build(input)
    }

    public func play(_ tracks: [TrackRow], startIndex: Int,
                     collection: WatchCollectionRef?, collectionTitle: String?) async {
        player.play(tracks: tracks, startAt: startIndex, source: .library)
    }

    public func setPlaying(_ playing: Bool) async {
        if playing { player.resumePlayback() } else { player.pausePlayback() }
    }

    public func togglePlayPause() async { player.togglePlayPause() }

    public func advance(by offset: Int) async {
        if offset >= 0 { player.next() } else { player.previous() }
    }

    public func jump(toIndex index: Int) async { player.skipToIndex(index) }

    public func seek(toSeconds seconds: Double) async { player.seek(to: seconds) }

    public func setShuffle(_ enabled: Bool) async { player.shuffle = enabled }

    public func setRepeat(_ mode: TonearmWatchProtocol.WatchRepeatMode) async {
        player.repeatMode = Self.playerRepeat(mode)
    }

    // MARK: - Mapping

    private static func watchRepeat(_ mode: RepeatMode) -> TonearmWatchProtocol.WatchRepeatMode {
        switch mode {
        case .off: .off
        case .all: .all
        case .one: .one
        }
    }

    private static func playerRepeat(_ mode: TonearmWatchProtocol.WatchRepeatMode) -> RepeatMode {
        switch mode {
        case .off: .off
        case .all: .all
        case .one: .one
        }
    }

    private func collectionRef(for source: QueueSource) -> WatchCollectionRef? {
        guard case .playlist(let playlist) = source, playlist.id != nil else { return nil }
        return WatchCollectionRef(kind: .playlist, id: PhoneWatchID.playlist(playlist))
    }

    private func collectionTitle(for source: QueueSource) -> String? {
        switch source {
        case .playlist(let playlist): playlist.title
        case .source(let s): s.title
        default: nil
        }
    }
}
#endif
