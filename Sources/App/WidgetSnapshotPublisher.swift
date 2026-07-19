import Foundation
import WidgetKit
import TonearmCore

@MainActor
enum WidgetSnapshotPublisher {
    static func publish(appState: AppState, player: AudioPlayer, now: Date = Date()) {
        publish(
            playback: playbackInput(from: player),
            recentlyPlayed: appState.recentlyPlayed.map(WidgetSnapshotBuilder.TrackInput.init(row:)),
            now: now,
            reloadTimelines: true
        )
    }

    static func publish(player: AudioPlayer, now: Date = Date()) {
        let previous = WidgetSnapshotStore.load(now: now)
        publish(
            playback: playbackInput(from: player),
            recentlyPlayed: previous.recentlyPlayed.map(WidgetSnapshotBuilder.TrackInput.init(snapshot:)),
            now: now,
            reloadTimelines: true
        )
    }

    static func publishEmpty(now: Date = Date()) {
        let snapshot = WidgetSnapshot.empty(now: now)
        WidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func publish(
        playback: WidgetSnapshotBuilder.PlaybackInput,
        recentlyPlayed: [WidgetSnapshotBuilder.TrackInput],
        now: Date,
        reloadTimelines: Bool
    ) {
        let snapshot = WidgetSnapshotBuilder.build(
            playback: playback,
            recentlyPlayed: recentlyPlayed,
            now: now
        )
        WidgetSnapshotStore.save(snapshot)
        if reloadTimelines {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private static func playbackInput(from player: AudioPlayer) -> WidgetSnapshotBuilder.PlaybackInput {
        WidgetSnapshotBuilder.PlaybackInput(
            track: player.currentTrack.map(WidgetSnapshotBuilder.TrackInput.init(row:)),
            isPlaying: player.isAdvancing,
            elapsed: player.currentTime,
            duration: player.duration
        )
    }
}

extension WidgetSnapshotBuilder.TrackInput {
    init(row: TrackRow) {
        let artist = row.album?.albumArtist
            ?? row.album?.artist
            ?? row.artist?.name
            ?? (row.asset?.kind == .remote ? PlaybackDisplayPolicy.providerName(for: row.source) : row.source?.title)
        self.init(
            id: row.track.id,
            title: row.track.title,
            artist: artist,
            albumTitle: row.album?.title,
            duration: row.track.durationSec,
            artworkID: row.album?.artworkId ?? row.source?.iaIdentifier
        )
    }

    init(snapshot: WidgetTrackSnapshot) {
        self.init(
            id: snapshot.id,
            title: snapshot.title,
            artist: snapshot.artist,
            albumTitle: snapshot.albumTitle,
            duration: snapshot.duration,
            artworkID: snapshot.artworkID
        )
    }
}
