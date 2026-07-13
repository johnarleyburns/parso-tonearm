import Foundation

enum WidgetArtworkStatus: String, Codable, Equatable, Hashable {
    case available
    case missing
}

struct WidgetTrackSnapshot: Codable, Equatable, Hashable {
    var id: Int64?
    var title: String
    var artist: String
    var albumTitle: String?
    var duration: Double?
    var artworkID: String?
    var artworkStatus: WidgetArtworkStatus

    var stableID: String {
        if let id { return "track-\(id)" }
        return "\(title)|\(artist)|\(albumTitle ?? "")"
    }

    var hasArtwork: Bool {
        artworkStatus == .available
    }
}

struct WidgetNowPlayingSnapshot: Codable, Equatable {
    var track: WidgetTrackSnapshot
    var isPlaying: Bool
    var elapsed: Double
    var duration: Double
    var progress: Double
    var updatedAt: Date
}

struct WidgetSnapshot: Codable, Equatable {
    var generatedAt: Date
    var nowPlaying: WidgetNowPlayingSnapshot?
    var recentlyPlayed: [WidgetTrackSnapshot]

    static func empty(now: Date) -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: now, nowPlaying: nil, recentlyPlayed: [])
    }

    func isStale(at now: Date, staleAfter: TimeInterval) -> Bool {
        now.timeIntervalSince(generatedAt) > staleAfter
    }
}

enum WidgetTimelineState: Equatable {
    case empty
    case fresh
    case stale
}

struct WidgetTimelineEntrySnapshot: Equatable {
    var date: Date
    var snapshot: WidgetSnapshot
    var state: WidgetTimelineState
    var nextRefreshDate: Date
}

enum WidgetSnapshotTimeline {
    static let staleAfter: TimeInterval = 30 * 60
    static let minimumRefreshInterval: TimeInterval = 5 * 60

    static func entry(for snapshot: WidgetSnapshot, now: Date) -> WidgetTimelineEntrySnapshot {
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

enum WidgetSnapshotBuilder {
    static let recentLimit = 5
    static let maxDisplayCharacters = 96

    struct TrackInput: Equatable {
        var id: Int64?
        var title: String
        var artist: String?
        var albumTitle: String?
        var duration: Double?
        var artworkID: String?
    }

    struct PlaybackInput: Equatable {
        var track: TrackInput?
        var isPlaying: Bool
        var elapsed: Double
        var duration: Double
    }

    static func build(
        playback: PlaybackInput,
        recentlyPlayed: [TrackInput],
        now: Date
    ) -> WidgetSnapshot {
        let nowPlaying = playback.track.map { input in
            let duration = normalizedSeconds(playback.duration > 0 ? playback.duration : input.duration)
            let elapsed = min(max(0, normalizedSeconds(playback.elapsed) ?? 0), duration ?? 0)
            let total = duration ?? 0
            let progress = total > 0 ? min(1, max(0, elapsed / total)) : 0
            return WidgetNowPlayingSnapshot(
                track: trackSnapshot(from: input),
                isPlaying: playback.isPlaying,
                elapsed: elapsed,
                duration: total,
                progress: progress,
                updatedAt: now
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
        return WidgetTrackSnapshot(
            id: input.id,
            title: displayText(input.title, fallback: "Untitled Track"),
            artist: displayText(input.artist ?? "", fallback: "Unknown Artist"),
            albumTitle: optionalDisplayText(input.albumTitle),
            duration: normalizedSeconds(input.duration),
            artworkID: normalizedArtworkID,
            artworkStatus: normalizedArtworkID == nil ? .missing : .available
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
