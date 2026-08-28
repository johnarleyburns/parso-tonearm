#if os(watchOS)
import AppIntents
import Foundation
import TonearmWatchCore

/// Siri / Shortcuts entry points for **downloaded** playback on the watch (Phase 11, §12
/// "App Intent/Siri entry for downloaded playback if platform-supported"). Every intent here
/// drives the local engine only — an intent never reaches a remote provider or controls the
/// phone, matching the watch's offline-first contract.

struct PlayDownloadedPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Downloaded Playlist"
    // Note: App Intent descriptions must not contain the word "apple" (App Store validation 90626).
    static let description = IntentDescription("Plays a playlist you've downloaded for offline listening.")
    static let openAppWhenRun = true

    @Parameter(title: "Playlist")
    var playlistName: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = WatchAppAssembly.shared.model
        await model.refresh()
        let titles = model.playlists.map(\.title)
        guard !titles.isEmpty else {
            throw WatchIntentError("No playlists are downloaded to this watch yet.")
        }
        guard let matched = WatchPlaylistNameMatch.best(playlistName, in: titles),
              let playlist = model.playlists.first(where: { $0.title == matched }) else {
            throw WatchIntentError("No downloaded playlist matched \u{201C}\(playlistName)\u{201D}.")
        }
        let tracks = model.readyTracks(forPlaylist: playlist.id)
        guard !tracks.isEmpty else {
            throw WatchIntentError("\u{201C}\(playlist.title)\u{201D} has no downloaded tracks.")
        }
        WatchPlayer.shared.play(tracks: tracks, startAt: 0)
        return .result()
    }
}

struct ResumeWatchPlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Platterhead"
    static let description = IntentDescription("Resumes your last downloaded track.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = WatchPlayer.shared
        if player.currentTrack == nil {
            await player.restorePositionIfAvailable()
        }
        guard player.currentTrack != nil else {
            throw WatchIntentError("There is nothing to resume.")
        }
        if !player.isPlaying { player.togglePlayPause() }
        player.navigateToNowPlaying()
        return .result()
    }
}

struct WatchShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayDownloadedPlaylistIntent(),
            phrases: [
                "Play a playlist in \(.applicationName)",
                "Play a downloaded playlist in \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list")
        AppShortcut(
            intent: ResumeWatchPlaybackIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume playback in \(.applicationName)"
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill")
    }
}

struct WatchIntentError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
#endif
