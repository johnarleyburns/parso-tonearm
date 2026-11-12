#if !os(watchOS)
import Foundation

/// Identity of one slot in the play queue. Distinct from the track ID so the same
/// track queued twice, reordered, or looped is never ambiguous.
public struct QueueOccurrenceID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

extension AudioPlayer {
    /// Compatibility setter behind `queue = rows`: matches surviving rows to existing entries in
    /// order, so reorder/delete/insert keep identity and origin and duplicates stay distinct.
    /// Rows with no match become `.context` entries.
    func setQueueRows(_ rows: [TrackRow]) {
        let old = queueEntries
        var used = Set<Int>()
        var cursor = 0
        var result: [PlaybackQueueEntry] = []
        for row in rows {
            let match = (cursor..<old.count).first { !used.contains($0) && old[$0].row.track.id == row.track.id }
                ?? old.indices.first { !used.contains($0) && old[$0].row.track.id == row.track.id }
            if let match {
                used.insert(match)
                cursor = match + 1
                var entry = old[match]
                entry.row = row
                result.append(entry)
            } else {
                result.append(PlaybackQueueEntry(row: row, origin: .context))
            }
        }
        if result != old { queueEntries = result }
    }
}
#endif
