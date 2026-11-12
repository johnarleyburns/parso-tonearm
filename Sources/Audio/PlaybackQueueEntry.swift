#if !os(watchOS)
import Foundation

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
    /// BPM/key snapshot for a mix match, captured when the entry was created.
    public private(set) var mixBPM: Double?
    public private(set) var mixCamelotKey: String?

    /// A `.mixMatched` origin without a valid BPM/key snapshot is an invariant failure, so it is
    /// recorded as the broader `.soundSimilar` origin instead.
    public init(id: QueueOccurrenceID = QueueOccurrenceID(), row: TrackRow, origin: Origin,
                mixBPM: Double? = nil, mixCamelotKey: String? = nil) {
        self.id = id
        self.row = row
        if case .keepPlaying(.mixMatched) = origin {
            if let p = KeepPlayingProvenance(reason: .mixMatched, bpm: mixBPM, camelotKey: mixCamelotKey) {
                self.origin = origin
                self.mixBPM = p.bpm
                self.mixCamelotKey = p.camelotKey
            } else {
                self.origin = .keepPlaying(.soundSimilar)
            }
        } else {
            self.origin = origin
        }
    }

    /// Nil for non-Keep-Playing entries; otherwise the persisted-by-occurrence explanation.
    public var provenance: KeepPlayingProvenance? {
        guard case .keepPlaying(let reason) = origin else { return nil }
        return KeepPlayingProvenance(reason: reason, bpm: mixBPM, camelotKey: mixCamelotKey)
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
        _ rows: [TrackRow], reason: KeepPlayingRecommendationReason,
        mix: [Int64: DJLoadTrackInfo] = [:], in state: Self
    ) -> Self {
        var state = state.normalized
        state.queue.append(contentsOf: rows.map { row in
            let info = row.track.id.flatMap { mix[$0] }
            return PlaybackQueueEntry(row: row, origin: .keepPlaying(reason),
                                      mixBPM: info?.bpm, mixCamelotKey: info?.camelotKey)
        })
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
