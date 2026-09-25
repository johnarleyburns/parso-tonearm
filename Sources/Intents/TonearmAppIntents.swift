#if !os(watchOS)
import AppIntents
import Foundation

/// Playback-starting intents conform to `AudioPlaybackIntent` (iOS 17+ /
/// macOS 14+), the App Intents protocol for intents that start or change
/// audio playback. It tells the system this intent — run in the app process
/// with `openAppWhenRun = false` — is meant to start audio, which is exactly
/// the hands-free CarPlay case (docs/plans/carplay-search-ios27-handoff.md
/// T3). Before iOS 27 an audio app can't show CPSearchTemplate in CarPlay at
/// all, so on iOS 18 these intents are the only way to find music by name
/// while driving.
public struct TonearmPlayPlaylistIntent: AudioPlaybackIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Play Playlist"
    public static let description = IntentDescription("Starts a Platterhead playlist.")
    // Real report (docs/plans/carplay-voice-search-plan.md §2), confirmed
    // against a real Apple Developer Forums thread: `openAppWhenRun = true`
    // is BLOCKED entirely while CarPlay is active ("Sorry, I can't do that
    // while you're driving") — a custom intent that tries to foreground the
    // app never even runs. `false` starts playback directly against the
    // live `AudioPlayer.shared` singleton (this file already runs in the
    // main app process, not a satellite extension) without ever needing the
    // screen — the fix for driving, and honestly better UX at rest too.
    public static let openAppWhenRun = false

    @Parameter(title: "Playlist")
    public var playlistName: String

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await TonearmIntentRunner.playPlaylist(named: playlistName)
        return .result(dialog: "Playing \(playlistName)")
    }
}

public struct TonearmPlayArtistIntent: AudioPlaybackIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Play Artist"
    public static let description = IntentDescription("Starts all Platterhead tracks by an artist.")
    public static let openAppWhenRun = false  // see TonearmPlayPlaylistIntent

    @Parameter(title: "Artist")
    public var artistName: String

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await TonearmIntentRunner.playArtist(named: artistName)
        return .result(dialog: "Playing \(artistName)")
    }
}

/// Real gap (docs/plans/carplay-voice-search-plan.md §1): only playlist and
/// artist could be voice-triggered — "play Hotel California," the single
/// most natural request, had no path at all.
///
/// The spoken flow is two turns: "Play a song in Platterhead" → Siri asks
/// for the song. App Shortcut phrases can't carry a free-text `String`
/// parameter, so "Play Hotel California in Platterhead" in one sentence
/// needs `INPlayMediaIntent` (an Intents extension) or the iOS 27 App
/// Intents `.audio` schema — not this intent.
public struct TonearmPlaySongIntent: AudioPlaybackIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Play Song"
    public static let description = IntentDescription("Plays a song in Platterhead.")
    public static let openAppWhenRun = false  // see TonearmPlayPlaylistIntent

    @Parameter(title: "Song")
    public var songTitle: String
    @Parameter(title: "Artist")
    public var artistName: String?

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let spoken = try await TonearmIntentRunner.playSong(title: songTitle, artist: artistName)
        if let artist = spoken.artist {
            return .result(dialog: "Playing \(spoken.title) by \(artist)")
        }
        return .result(dialog: "Playing \(spoken.title)")
    }
}

public struct TonearmResumeIntent: AudioPlaybackIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Resume Platterhead"
    public static let description = IntentDescription("Resumes Platterhead playback.")
    public static let openAppWhenRun = false  // see TonearmPlayPlaylistIntent

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await TonearmIntentRunner.run(.resume)
        return .result(dialog: "Resuming playback")
    }
}

public struct TonearmSleepTimerIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Set Sleep Timer"
    public static let description = IntentDescription("Sets a Platterhead sleep timer in minutes.")
    public static let openAppWhenRun = true

    @Parameter(title: "Minutes", default: 30)
    public var minutes: Int

    @MainActor
    public func perform() async throws -> some IntentResult {
        switch IntentResolver.resolveSleepTimer(minutes: minutes) {
        case .command(let command):
            try await TonearmIntentRunner.run(command)
        case .failure(let failure):
            throw TonearmIntentError(failure)
        }
        return .result()
    }
}

public struct TonearmAddSourceIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Add Archive Source"
    public static let description = IntentDescription("Adds an archive.org library to Platterhead.")
    public static let openAppWhenRun = true

    @Parameter(title: "URL")
    public var rawURL: String

    @MainActor
    public func perform() async throws -> some IntentResult {
        switch IntentResolver.resolveAddSource(rawURL: rawURL) {
        case .command(let command):
            try await TonearmIntentRunner.run(command)
        case .failure(let failure):
            throw TonearmIntentError(failure)
        }
        return .result()
    }
}

public struct TonearmShortcutsProvider: AppShortcutsProvider {
    public static let shortcutTileColor: ShortcutTileColor = .teal

    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TonearmPlayPlaylistIntent(),
            phrases: [
                "Play a playlist in \(.applicationName)",
                "Start a Platterhead playlist in \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: TonearmPlayArtistIntent(),
            phrases: [
                "Play an artist in \(.applicationName)",
                "Start an artist in \(.applicationName)"
            ],
            shortTitle: "Play Artist",
            systemImageName: "music.mic"
        )
        AppShortcut(
            intent: TonearmPlaySongIntent(),
            phrases: [
                "Play a song in \(.applicationName)",
                "Play a track in \(.applicationName)"
            ],
            shortTitle: "Play Song",
            systemImageName: "music.note"
        )
        AppShortcut(
            intent: TonearmResumeIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume Platterhead in \(.applicationName)"
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: TonearmSleepTimerIntent(),
            phrases: [
                "Set a sleep timer in \(.applicationName)",
                "Start a Platterhead sleep timer in \(.applicationName)"
            ],
            shortTitle: "Sleep Timer",
            systemImageName: "moon.zzz"
        )
        AppShortcut(
            intent: TonearmAddSourceIntent(),
            phrases: [
                "Add an archive source in \(.applicationName)",
                "Add a source to \(.applicationName)"
            ],
            shortTitle: "Add Source",
            systemImageName: "link.badge.plus"
        )
    }
}

@MainActor
public enum TonearmIntentRunner {
    public static func playPlaylist(named name: String) async throws {
        let store = LibraryStore.shared
        let playlists = try await store.allPlaylists()
        let candidates = playlists.compactMap { playlist -> IntentResolver.PlaylistCandidate? in
            guard let id = playlist.id else { return nil }
            return IntentResolver.PlaylistCandidate(id: id, title: playlist.title)
        }

        switch IntentResolver.resolvePlaylist(named: name, playlists: candidates) {
        case .command(let command):
            try await run(command, playlists: playlists)
        case .failure(let failure):
            throw TonearmIntentError(failure)
        }
    }

    public static func playArtist(named name: String) async throws {
        let store = LibraryStore.shared
        let artists = try await store.allArtists()
        let candidates = artists.map { IntentResolver.ArtistCandidate(name: $0.name) }

        switch IntentResolver.resolveArtist(named: name, artists: candidates) {
        case .command(let command):
            try await run(command)
        case .failure(let failure):
            throw TonearmIntentError(failure)
        }
    }

    /// Returns the resolved (title, artist) so the intent's spoken
    /// confirmation says the real match Siri found, not just an echo of
    /// whatever the user said (which might have been corrected by fuzzy
    /// matching, e.g. a mishearing).
    public static func playSong(title: String, artist: String?) async throws -> (title: String, artist: String?) {
        let store = LibraryStore.shared
        let rows = try await store.allTrackRows()
        let candidates = rows.compactMap { row -> IntentResolver.SongCandidate? in
            guard let trackId = row.track.id else { return nil }
            return IntentResolver.SongCandidate(
                trackId: trackId, title: row.track.title,
                artist: row.artist?.name ?? row.album?.artist)
        }

        switch IntentResolver.resolveSong(title: title, artist: artist, songs: candidates) {
        case .command(let command):
            try await run(command)
            guard case .playSong(_, let resolvedTitle, let resolvedArtist) = command else {
                return (title, artist)
            }
            return (resolvedTitle, resolvedArtist)
        case .failure(let failure):
            throw TonearmIntentError(failure)
        }
    }

    public static func run(_ command: IntentResolver.Command) async throws {
        try await run(command, playlists: nil)
    }

    private static func run(_ command: IntentResolver.Command, playlists: [Playlist]?) async throws {
        switch command {
        case .playPlaylist(let id, let title):
            let rows = try await LibraryStore.shared.playlistItems(playlistId: id)
            guard !rows.isEmpty else {
                throw TonearmIntentError("Playlist \"\(title)\" has no playable tracks.")
            }
            let playlist = playlists?.first { $0.id == id }
                ?? Playlist(id: id, title: title, kind: .manual, folderBookmark: nil, watch: false)
            AudioPlayer.shared.play(tracks: rows, startAt: 0, source: .playlist(playlist))

        case .playArtist(let name):
            let rows = try await LibraryStore.shared.tracks(forArtist: name)
            guard !rows.isEmpty else {
                throw TonearmIntentError("Artist \"\(name)\" has no playable tracks.")
            }
            AudioPlayer.shared.play(tracks: rows, startAt: 0, source: .library)

        case .playSong(let trackId, let title, _):
            guard let row = try await LibraryStore.shared.trackRow(id: trackId) else {
                throw TonearmIntentError("\"\(title)\" is no longer in your library.")
            }
            AudioPlayer.shared.play(tracks: [row], startAt: 0, source: .library)

        case .resume:
            await AudioPlayer.shared.withRestoredQueue { AudioPlayer.shared.resumePlayback() }

        case .setSleepTimer(let plan):
            AudioPlayer.shared.applySleepTimer(plan)

        case .addSource(let rawURL):
            let preferFLAC = UserDefaults.standard.bool(forKey: "preferFLAC")
            let service = SourceService(preferFLAC: preferFLAC)
            let preview = try await service.preview(from: rawURL)
            _ = try await service.add(preview: preview, followUpdates: true, store: LibraryStore.shared)
        }
    }
}

public struct TonearmIntentError: LocalizedError {
    public var errorDescription: String?

    public init(_ message: String) {
        errorDescription = message
    }

    public init(_ failure: IntentResolver.Failure) {
        errorDescription = failure.message
    }
}

private extension IntentResolver.Failure {
    var message: String {
        switch self {
        case .emptyLibrary(let kind):
            return "Platterhead has no \(kind.displayName) to match."
        case .emptyParameter(let kind):
            return "Enter a \(kind.displayName) value."
        case .noMatch(let kind, let query):
            return "No \(kind.displayName) matched \"\(query)\"."
        case .ambiguous(let kind, let query, let matches):
            return "\(kind.displayName.capitalized) \"\(query)\" matched more than one result: \(matches.joined(separator: ", "))."
        case .malformedURL(let rawURL):
            return "\"\(rawURL)\" is not a supported archive.org URL."
        case .invalidSleepTimerMinutes(let minutes):
            return "Sleep timer minutes must be between \(IntentResolver.minimumSleepMinutes) and \(IntentResolver.maximumSleepMinutes), not \(minutes)."
        }
    }
}

private extension IntentResolver.TargetKind {
    var displayName: String {
        switch self {
        case .playlist:
            return "playlist"
        case .artist:
            return "artist"
        case .song:
            return "song"
        case .sourceURL:
            return "source URL"
        case .sleepTimer:
            return "sleep timer"
        }
    }
}
#endif
