#if !os(watchOS)
import Foundation

/// What the Listen tab's single resume surface should say. Pure value derived
/// from live playback state, so visibility and wording are unit-testable
/// without a player or database.
///
/// The card intentionally appears only while playback is paused: an active
/// session is already represented by the mini player, and the Listen tab
/// suppresses that mini player while this card is visible so there is exactly
/// one resume surface on the screen.
public struct ContinueListeningPresentation: Equatable, Sendable {
    public enum Context: Equatable, Sendable {
        case album(String)
        case playlist(String)
        case queue

        public var name: String? {
            switch self {
            case .album(let name), .playlist(let name): return name
            case .queue: return nil
            }
        }
    }

    /// Below this, a paused single track is treated as "not really started"
    /// rather than something to resume.
    public static let minimumMeaningfulElapsed: Double = 20
    /// Never offer to resume in the last few seconds of a track; that is the
    /// end-of-track state, not a place worth returning to.
    public static let endGuard: Double = 15

    public let currentTrack: TrackRow
    public let context: Context
    /// 1-based position within the queue.
    public let position: Int
    public let total: Int
    public let elapsed: Double
    public let duration: Double
    public let unplayedCount: Int

    public init?(
        currentTrack: TrackRow?,
        queue: [TrackRow],
        index: Int,
        elapsed: Double,
        duration: Double,
        isPlaying: Bool,
        isAmbient: Bool,
        queueSource: QueueSource
    ) {
        guard !isAmbient, !isPlaying, let currentTrack, !queue.isEmpty else { return nil }

        let total = queue.count
        let clampedIndex = min(max(index, 0), total - 1)
        let unplayed = max(0, total - clampedIndex - 1)
        let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0
        let safeDuration = duration.isFinite ? max(0, duration) : 0

        let progressIsMeaningful =
            safeElapsed >= Self.minimumMeaningfulElapsed
            && (safeDuration <= 0 || safeElapsed <= safeDuration - Self.endGuard)
        // More than one upcoming track means resuming is about the queue, not
        // about interrupting a single song mid-phrase.
        guard unplayed > 1 || progressIsMeaningful else { return nil }

        self.currentTrack = currentTrack
        self.context = Self.context(queue: queue, queueSource: queueSource)
        self.position = clampedIndex + 1
        self.total = total
        self.elapsed = safeElapsed
        self.duration = safeDuration
        self.unplayedCount = unplayed
    }

    /// Human-readable progress without localized copy around it: the view
    /// supplies the localized headline, and numbers/times stay language-neutral.
    public var progressText: String {
        let positionText = "\(position) / \(total)"
        guard duration > 0 else {
            return "\(positionText) · \(Self.timeText(elapsed))"
        }
        return "\(positionText) · \(Self.timeText(elapsed)) / \(Self.timeText(duration))"
    }

    static func timeText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secondsPart = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secondsPart)
        }
        return String(format: "%d:%02d", minutes, secondsPart)
    }

    private static func context(queue: [TrackRow], queueSource: QueueSource) -> Context {
        switch queueSource {
        case .playlist(let playlist):
            let title = playlist.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return .playlist(title) }
        case .continuation:
            return .queue
        case .ambient:
            return .queue
        case .library, .source, .none:
            break
        }
        if let album = singleAlbumTitle(in: queue) { return .album(album) }
        return .queue
    }

    /// Only claim "album" when every queued row really shares one album with a
    /// usable title. A playlist/queue mixing albums stays a queue.
    private static func singleAlbumTitle(in queue: [TrackRow]) -> String? {
        let albumIDs = queue.map { $0.track.albumId ?? $0.album?.id }
        guard let first = albumIDs.first, first != nil,
              albumIDs.allSatisfy({ $0 == first })
        else { return nil }
        let title = queue.compactMap { $0.album?.title }.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }
        return title
    }
}
#endif
