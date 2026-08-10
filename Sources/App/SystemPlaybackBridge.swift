import AVFoundation
import Foundation
import MediaPlayer
import UIKit
import TonearmCore

/// The app-side implementation of `PlaybackPlatformBridge`: owns every iOS-only
/// integration `AudioPlayer` used to hold inline — the audio session,
/// `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`, artwork decoding, and
/// widget publishing. `AudioPlayer` keeps the byte-for-byte
/// playback logic; this class keeps the platform reasoning.
@MainActor
final class SystemPlaybackBridge: PlaybackPlatformBridge {
    private var routeChangeObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    var sampleRate: Double {
        AVAudioSession.sharedInstance().sampleRate
    }

    func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    func setupRemoteCommands(
        resume: @escaping () -> Void,
        pause: @escaping () -> Void,
        next: @escaping () -> Void,
        previous: @escaping () -> Void,
        seek: @escaping (Double) -> Void
    ) {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in resume(); return .success }
        c.pauseCommand.addTarget { _ in pause(); return .success }
        c.nextTrackCommand.addTarget { _ in next(); return .success }
        c.previousTrackCommand.addTarget { _ in previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            seek(e.positionTime)
            return .success
        }
    }

    func startObservers(
        routeShouldPause: @escaping () -> Void,
        interruptionPause: @escaping () -> Void,
        interruptionResume: @escaping () -> Void
    ) {
        let routeCallback = CallbackBox(routeShouldPause)
        let pauseCallback = CallbackBox(interruptionPause)
        let resumeCallback = CallbackBox(interruptionResume)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { notification in
            let notification = NotificationBox(notification)
            Task { @MainActor in
                guard let reasonRaw = notification.value.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
                let prevKey = AVAudioSessionRouteChangePreviousRouteKey
                let prevRoute = notification.value.userInfo?[prevKey] as? AVAudioSessionRouteDescription
                let prevHadExternal = prevRoute?.outputs.contains(where: { $0.portType != .builtInSpeaker }) == true

                switch reason {
                case .oldDeviceUnavailable:
                    if prevHadExternal { routeCallback.call() }
                case .routeConfigurationChange:
                    let currentOutputs = AVAudioSession.sharedInstance().currentRoute.outputs
                    let isBuiltInOnly = currentOutputs.allSatisfy { $0.portType == .builtInSpeaker }
                    if isBuiltInOnly && prevHadExternal { routeCallback.call() }
                default: break
                }
            }
        }

        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { notification in
            let notification = NotificationBox(notification)
            guard let typeRaw = notification.value.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
            let optionsRaw = notification.value.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                switch type {
                case .began:
                    pauseCallback.call()
                case .ended:
                    if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                        resumeCallback.call()
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    func refreshNowPlaying(_ player: AudioPlayer) {
        guard let row = player.currentTrack else {
            clearNowPlaying()
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: row.track.title,
            MPMediaItemPropertyArtist: row.album?.artist ?? row.artist?.name ?? PlaybackDisplayPolicy.providerName(for: row.source),
            MPMediaItemPropertyPlaybackDuration: player.isAmbient ? 0 : player.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.isAmbient ? 0 : player.currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: player.isAdvancing ? 1.0 : 0.0
        ]
        info[MPMediaItemPropertyAlbumTitle] = row.album?.title
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        WidgetSnapshotPublisher.publish(player: player)

        Task {
            if let image = await ArtworkService.shared.artwork(forTrackRow: row) {
                // MediaPlayer invokes this handler on its private access queue,
                // not on the main actor. Build it in a nonisolated helper so
                // Swift concurrency does not retain SystemPlaybackBridge's
                // @MainActor isolation in the callback.
                let art = makeMediaArtwork(image)
                var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                current[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current

                if let artworkID = row.album?.artworkId ?? row.source?.iaIdentifier {
                    // The save must complete before the re-publish so the snapshot's
                    // filename-exists check (Fix 4) sees the file on disk.
                    WidgetArtworkStore.save(image: image, for: artworkID)
                    pruneWidgetArtwork(player)
                    WidgetSnapshotPublisher.publish(player: player)
                }
            }
        }
    }

    func refreshNowPlayingTime(_ player: AudioPlayer) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isAdvancing ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func publishSnapshot(_ player: AudioPlayer) {
        WidgetSnapshotPublisher.publish(player: player)
    }

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        WidgetSnapshotPublisher.publishEmpty()
    }

    func prefetchArtwork(for row: TrackRow) {
        Task.detached(priority: .background) {
            _ = await ArtworkService.shared.artwork(forTrackRow: row)
        }
    }

    /// Bounds the App Group artwork directory: keeps only files referenced by the
    /// current snapshot (now playing + recently played).
    private func pruneWidgetArtwork(_ player: AudioPlayer) {
        let snapshot = WidgetSnapshotStore.load()
        var keep = Set<String>()
        if let id = snapshot.nowPlaying?.track.artworkID {
            keep.insert(WidgetArtworkStore.filename(for: id))
        }
        for track in snapshot.recentlyPlayed {
            if let id = track.artworkID {
                keep.insert(WidgetArtworkStore.filename(for: id))
            }
        }
        if let id = player.currentTrack.flatMap({ $0.album?.artworkId ?? $0.source?.iaIdentifier }) {
            keep.insert(WidgetArtworkStore.filename(for: id))
        }
        WidgetArtworkStore.prune(keeping: keep)
    }
}

/// `MPMediaItemArtwork` may request artwork from MediaPlayer's `accessQueue`.
/// Keep the request handler nonisolated; capturing a handler created inside the
/// @MainActor bridge makes Swift's executor check trap on iOS 18.7.
private func makeMediaArtwork(_ image: UIImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
}

private struct CallbackBox: @unchecked Sendable {
    let value: () -> Void
    init(_ value: @escaping () -> Void) { self.value = value }
    func call() { value() }
}

private struct NotificationBox: @unchecked Sendable {
    let value: Notification
    init(_ value: Notification) { self.value = value }
}
