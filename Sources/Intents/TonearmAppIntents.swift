import AppIntents
import Foundation

public struct TonearmPlayPlaylistIntent: AppIntent {
    public init() {}
    public static var title: LocalizedStringResource = "Play Playlist"
    public static var description = IntentDescription("Starts a Tonearm playlist.")
    public static var openAppWhenRun = true

    @Parameter(title: "Playlist")
    public var playlistName: String

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await TonearmIntentRunner.playPlaylist(named: playlistName)
        return .result()
    }
}

public struct TonearmPlayArtistIntent: AppIntent {
    public init() {}
    public static var title: LocalizedStringResource = "Play Artist"
    public static var description = IntentDescription("Starts all Tonearm tracks by an artist.")
    public static var openAppWhenRun = true

    @Parameter(title: "Artist")
    public var artistName: String

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await TonearmIntentRunner.playArtist(named: artistName)
        return .result()
    }
}

public struct TonearmResumeIntent: AppIntent {
    public init() {}
    public static var title: LocalizedStringResource = "Resume Tonearm"
    public static var description = IntentDescription("Resumes Tonearm playback.")
    public static var openAppWhenRun = true

    @MainActor
    public func perform() async throws -> some IntentResult {
        try await TonearmIntentRunner.run(.resume)
        return .result()
    }
}

public struct TonearmSleepTimerIntent: AppIntent {
    public init() {}
    public static var title: LocalizedStringResource = "Set Sleep Timer"
    public static var description = IntentDescription("Sets a Tonearm sleep timer in minutes.")
    public static var openAppWhenRun = true

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
    public static var title: LocalizedStringResource = "Add Archive Source"
    public static var description = IntentDescription("Adds an archive.org source to Tonearm.")
    public static var openAppWhenRun = true

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
    public static var shortcutTileColor: ShortcutTileColor = .teal

    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TonearmPlayPlaylistIntent(),
            phrases: [
                "Play a playlist in \(.applicationName)",
                "Start a Tonearm playlist in \(.applicationName)"
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
            intent: TonearmResumeIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume Tonearm in \(.applicationName)"
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: TonearmSleepTimerIntent(),
            phrases: [
                "Set a sleep timer in \(.applicationName)",
                "Start a Tonearm sleep timer in \(.applicationName)"
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

        case .resume:
            AudioPlayer.shared.resumePlayback()

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
            return "Tonearm has no \(kind.displayName) to match."
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
        case .sourceURL:
            return "source URL"
        case .sleepTimer:
            return "sleep timer"
        }
    }
}
