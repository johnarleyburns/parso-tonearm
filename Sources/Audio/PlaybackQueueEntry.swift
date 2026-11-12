#if !os(watchOS)
import Foundation

/// Why Keep Playing chose a track. Closed on purpose: UI labels switch over it exhaustively.
public enum KeepPlayingRecommendationReason: Equatable, Sendable {
    case mixMatched
    case soundSimilar
    case modelUnavailableShuffle
    case noMatchShuffle
}

/// One slot in the play queue: the row, its occurrence identity and why it is there.
/// Origin is never inferred from `TrackRow.id` — the same track may occur several times.
public struct PlaybackQueueEntry: Identifiable, Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        case context
        case listenerNext
        case listenerQueued
        case keepPlaying(KeepPlayingRecommendationReason)

        var isListener: Bool { self == .listenerNext || self == .listenerQueued }
        var isKeepPlaying: Bool {
            if case .keepPlaying = self { return true }
            return false
        }
    }

    public let id: QueueOccurrenceID
    public var row: TrackRow
    public var origin: Origin

    public init(id: QueueOccurrenceID = QueueOccurrenceID(), row: TrackRow, origin: Origin) {
        self.id = id
        self.row = row
        self.origin = origin
    }
}

extension QueueEditor.State where Element == PlaybackQueueEntry {
    /// Play Next: immediately after the current entry, ahead of every future entry.
    static func insertingListenerNext(_ row: TrackRow, in state: Self) -> Self {
        QueueEditor.insertNext(PlaybackQueueEntry(row: row, origin: .listenerNext), in: state)
    }

    /// Add to Queue: after every existing future listener entry, before context/Keep Playing.
    static func appendingListenerQueued(_ row: TrackRow, in state: Self) -> Self {
        var state = state.normalized
        let entry = PlaybackQueueEntry(row: row, origin: .listenerQueued)
        guard !state.queue.isEmpty else { return .init(queue: [entry], currentIndex: 0) }
        let lastListener = state.queue.indices.last {
            $0 > state.currentIndex && state.queue[$0].origin.isListener
        }
        state.queue.insert(entry, at: (lastListener ?? state.currentIndex) + 1)
        return state
    }

    /// Keep Playing only ever appends at the tail.
    static func appendingKeepPlaying(
        _ rows: [TrackRow], reason: KeepPlayingRecommendationReason, in state: Self
    ) -> Self {
        var state = state.normalized
        state.queue.append(contentsOf: rows.map { PlaybackQueueEntry(row: $0, origin: .keepPlaying(reason)) })
        return state
    }

    /// Drops unplayed (after current) Keep Playing entries; nothing else.
    static func removingUnplayedKeepPlaying(in state: Self) -> Self {
        var state = state.normalized
        var offset = 0
        state.queue.removeAll { entry in
            defer { offset += 1 }
            return offset > state.currentIndex && entry.origin.isKeepPlaying
        }
        return state
    }
}
#endif
