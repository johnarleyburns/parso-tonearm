import ActivityKit
import Foundation
import WidgetKit

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
        if #available(iOS 16.2, *) {
            NowPlayingLiveActivityController.shared.publish(snapshot)
        }
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
        if #available(iOS 16.2, *) {
            NowPlayingLiveActivityController.shared.publish(snapshot)
        }
    }

    private static func playbackInput(from player: AudioPlayer) -> WidgetSnapshotBuilder.PlaybackInput {
        WidgetSnapshotBuilder.PlaybackInput(
            track: player.currentTrack.map(WidgetSnapshotBuilder.TrackInput.init(row:)),
            isPlaying: player.isPlaying,
            elapsed: player.currentTime,
            duration: player.duration
        )
    }
}

extension WidgetSnapshotBuilder.TrackInput {
    init(row: TrackRow) {
        let artist = row.album?.albumArtist ?? row.album?.artist ?? row.source?.title
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

@available(iOS 16.2, *)
@MainActor
final class NowPlayingLiveActivityController {
    static let shared = NowPlayingLiveActivityController()

    private init() {}

    func publish(_ snapshot: WidgetSnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              UserDefaults.standard.object(forKey: "showLiveActivity") as? Bool ?? true else { return }

        guard let state = TonearmNowPlayingAttributes.ContentState(snapshot: snapshot) else {
            endAll()
            return
        }

        let attributes = TonearmNowPlayingAttributes(trackID: snapshot.nowPlaying?.track.id)
        let content = ActivityContent(
            state: state,
            staleDate: snapshot.generatedAt.addingTimeInterval(WidgetSnapshotTimeline.staleAfter),
            relevanceScore: state.isPlaying ? 1.0 : 0.5
        )

        Task {
            let activities = Activity<TonearmNowPlayingAttributes>.activities
            let matching = activities.first { activity in
                activity.attributes.trackID == attributes.trackID
            }

            for activity in activities where activity.id != matching?.id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }

            if let matching {
                await matching.update(content)
            } else if state.isPlaying {
                do {
                    _ = try Activity<TonearmNowPlayingAttributes>.request(
                        attributes: attributes,
                        content: content,
                        pushType: nil
                    )
                } catch {
                    print("NowPlayingLiveActivity: failed to request activity: \(error)")
                }
            }
        }
    }

    func endAll() {
        Task {
            for activity in Activity<TonearmNowPlayingAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
