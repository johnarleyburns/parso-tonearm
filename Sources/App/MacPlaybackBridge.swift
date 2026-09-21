// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

#if os(macOS)
import AVFoundation
import Foundation
import MediaPlayer
import TonearmCore

/// The Mac counterpart to `SystemPlaybackBridge`: `MPNowPlayingInfoCenter`
/// and `MPRemoteCommandCenter` are both available on macOS (unlike
/// `AVAudioSession`, which is iOS-only — macOS has no session-category
/// concept to configure, and no route-change/interruption notifications to
/// observe the way iOS does), and there is no widget snapshot to publish
/// (native Mac app, docs/plans/native-mac-app-plan.md §1 — no widget
/// extension). Mirrors `SystemPlaybackBridge`'s now-playing-info logic
/// exactly where the two platforms share real behavior.
@MainActor
final class MacPlaybackBridge: PlaybackPlatformBridge {
    private let engine = AVAudioEngine()

    var sampleRate: Double {
        engine.outputNode.outputFormat(forBus: 0).sampleRate
    }

    func configureSession() {}

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

    /// macOS has no `AVAudioSession` route-change/interruption notifications
    /// to observe — output-device switching and app interruption (another
    /// app grabbing exclusive audio access) aren't first-class concepts on
    /// the Mac audio stack the way they are on iOS.
    func startObservers(
        routeShouldPause: @escaping () -> Void,
        interruptionPause: @escaping () -> Void,
        interruptionResume: @escaping () -> Void
    ) {}

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

        Task {
            if let image = await ArtworkService.shared.artwork(forTrackRow: row) {
                let art = makeMediaArtwork(image)
                var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                current[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
        }
    }

    func refreshNowPlayingTime(_ player: AudioPlayer) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player.currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = player.isAdvancing ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func publishSnapshot(_ player: AudioPlayer) {}

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func prefetchArtwork(for row: TrackRow) {
        Task.detached(priority: .background) {
            _ = await ArtworkService.shared.artwork(forTrackRow: row)
        }
    }
}

/// `MPMediaItemArtwork` may request artwork from MediaPlayer's private access
/// queue; keep the request handler nonisolated, matching
/// `SystemPlaybackBridge`'s same reasoning.
private func makeMediaArtwork(_ image: PlatformImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
}
#endif
