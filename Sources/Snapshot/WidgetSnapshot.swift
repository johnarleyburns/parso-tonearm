import Foundation

public enum WidgetArtworkStatus: String, Codable, Equatable, Hashable {
    case available
    case missing
}

public struct WidgetTrackSnapshot: Codable, Equatable, Hashable {
    public var id: Int64?
    public var title: String
    public var artist: String
    public var albumTitle: String?
    public var duration: Double?
    public var artworkID: String?
    public var artworkStatus: WidgetArtworkStatus
    public var artworkFilename: String?

    public var stableID: String {
        if let id { return "track-\(id)" }
        return "\(title)|\(artist)|\(albumTitle ?? "")"
    }

    public var hasArtwork: Bool {
        artworkStatus == .available
    }
}

public struct WidgetNowPlayingSnapshot: Codable, Equatable {
    public var track: WidgetTrackSnapshot
    public var isPlaying: Bool
    public var elapsed: Double
    public var duration: Double
    public var progress: Double
    public var updatedAt: Date
    public var startDate: Date
    public var endDate: Date
}

public struct WidgetSnapshot: Codable, Equatable {
    public var generatedAt: Date
    public var nowPlaying: WidgetNowPlayingSnapshot?
    public var recentlyPlayed: [WidgetTrackSnapshot]

    public static func empty(now: Date) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: now, nowPlaying: nil, recentlyPlayed: [])
    }

    public func isStale(at now: Date, staleAfter: TimeInterval) -> Bool {
        now.timeIntervalSince(generatedAt) > staleAfter
    }
}

public enum WidgetTimelineState: Equatable {
    case empty
    case fresh
    case stale
}

public struct WidgetTimelineEntrySnapshot: Equatable {
    public var date: Date
    public var snapshot: WidgetSnapshot
    public var state: WidgetTimelineState
    public var nextRefreshDate: Date
}

public enum WidgetSnapshotTimeline {
    public static let staleAfter: TimeInterval = 30 * 60
    public static let minimumRefreshInterval: TimeInterval = 5 * 60

    public static func entry(for snapshot: WidgetSnapshot, now: Date) -> WidgetTimelineEntrySnapshot {
        let state: WidgetTimelineState
        if snapshot.nowPlaying == nil && snapshot.recentlyPlayed.isEmpty {
            state = .empty
        } else if snapshot.isStale(at: now, staleAfter: staleAfter) {
            state = .stale
        } else {
            state = .fresh
        }

        let staleDate = snapshot.generatedAt.addingTimeInterval(staleAfter)
        let minimumDate = now.addingTimeInterval(minimumRefreshInterval)
        let nextRefresh = max(staleDate, minimumDate)

        return WidgetTimelineEntrySnapshot(
            date: now,
            snapshot: snapshot,
            state: state,
            nextRefreshDate: nextRefresh
        )
    }
}

public enum WidgetSnapshotBuilder {
    public static let recentLimit = 5
    public static let maxDisplayCharacters = 96

    public struct TrackInput: Equatable {
        public var id: Int64?
        public var title: String
        public var artist: String?
        public var albumTitle: String?
        public var duration: Double?
        public var artworkID: String?

        public init(id: Int64?,
                    title: String,
                    artist: String?,
                    albumTitle: String?,
                    duration: Double?,
                    artworkID: String?) {
            self.id = id
            self.title = title
            self.artist = artist
            self.albumTitle = albumTitle
            self.duration = duration
            self.artworkID = artworkID
        }
    }

    public struct PlaybackInput: Equatable {
        public var track: TrackInput?
        public var isPlaying: Bool
        public var elapsed: Double
        public var duration: Double

        public init(track: TrackInput?,
                    isPlaying: Bool,
                    elapsed: Double,
                    duration: Double) {
            self.track = track
            self.isPlaying = isPlaying
            self.elapsed = elapsed
            self.duration = duration
        }
    }

    public static func build(
        playback: PlaybackInput,
        recentlyPlayed: [TrackInput],
        now: Date
    ) -> WidgetSnapshot {
        let nowPlaying = playback.track.map { input in
            let duration = normalizedSeconds(playback.duration > 0 ? playback.duration : input.duration)
            let elapsed = min(max(0, normalizedSeconds(playback.elapsed) ?? 0), duration ?? 0)
            let total = duration ?? 0
            let progress = total > 0 ? min(1, max(0, elapsed / total)) : 0
            let start = Date(timeInterval: -elapsed, since: now)
            let remaining = max(0, total - elapsed)
            let end = Date(timeInterval: remaining, since: now)
            return WidgetNowPlayingSnapshot(
                track: trackSnapshot(from: input),
                isPlaying: playback.isPlaying,
                elapsed: elapsed,
                duration: total,
                progress: progress,
                updatedAt: now,
                startDate: start,
                endDate: end
            )
        }

        return WidgetSnapshot(
            generatedAt: now,
            nowPlaying: nowPlaying,
            recentlyPlayed: recentSnapshots(from: recentlyPlayed)
        )
    }

    private static func recentSnapshots(from inputs: [TrackInput]) -> [WidgetTrackSnapshot] {
        var seen = Set<String>()
        var output: [WidgetTrackSnapshot] = []
        for input in inputs {
            let snapshot = trackSnapshot(from: input)
            guard seen.insert(snapshot.stableID).inserted else { continue }
            output.append(snapshot)
            if output.count == recentLimit { break }
        }
        return output
    }

    private static func trackSnapshot(from input: TrackInput) -> WidgetTrackSnapshot {
        let artworkID = input.artworkID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArtworkID = artworkID?.isEmpty == true ? nil : artworkID
        // Only reference an artwork file that already exists on disk: the JPEG is
        // written asynchronously after the first publish, and a dangling filename
        // renders as a blank rectangle instead of the SF-symbol fallback.
        let filename = normalizedArtworkID.flatMap { id -> String? in
            let name = WidgetArtworkStore.filename(for: id)
            guard let url = WidgetArtworkStore.imageURL(for: name),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return name
        }
        return WidgetTrackSnapshot(
            id: input.id,
            title: displayText(input.title, fallback: "Untitled Track"),
            artist: displayText(input.artist ?? "", fallback: "Unknown Artist"),
            albumTitle: optionalDisplayText(input.albumTitle),
            duration: normalizedSeconds(input.duration),
            artworkID: normalizedArtworkID,
            artworkStatus: normalizedArtworkID == nil ? .missing : .available,
            artworkFilename: filename
        )
    }

    private static func optionalDisplayText(_ value: String?) -> String? {
        let text = displayText(value ?? "", fallback: "")
        return text.isEmpty ? nil : text
    }

    private static func displayText(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? fallback : trimmed
        guard base.count > maxDisplayCharacters else { return base }
        let keep = max(0, maxDisplayCharacters - 3)
        return String(base.prefix(keep)) + "..."
    }

    private static func normalizedSeconds(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}
