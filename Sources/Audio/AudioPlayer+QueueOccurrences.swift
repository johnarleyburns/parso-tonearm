#if !os(watchOS)
import Foundation

/// Identity of one slot in the play queue. Distinct from the track ID so the same
/// track queued twice or reordered is never ambiguous.
public struct QueueOccurrenceID: Hashable, Sendable, Codable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

extension AudioPlayer {
    /// Keeps `queueOccurrences` parallel to `queue` after any edit, matching surviving rows in
    /// order so reorder/delete/insert keep identities and duplicates stay distinct.
    func reconcileQueueOccurrences(old: [TrackRow]) {
        var oldOccurrences = queueOccurrences
        if oldOccurrences.count != old.count { oldOccurrences = old.map { _ in QueueOccurrenceID() } }
        var used = Set<Int>()
        var cursor = 0
        var result: [QueueOccurrenceID] = []
        for row in queue {
            let match = (cursor..<old.count).first { !used.contains($0) && old[$0].track.id == row.track.id }
                ?? old.indices.first { !used.contains($0) && old[$0].track.id == row.track.id }
            if let match {
                used.insert(match)
                cursor = match + 1
                result.append(oldOccurrences[match])
            } else {
                result.append(QueueOccurrenceID())
            }
        }
        guard result != queueOccurrences || oldOccurrences.count != queueOccurrences.count else { return }
        queueOccurrences = result
    }

    /// A replacement queue shares no identities with the old one, even for the same tracks.
    func replaceQueueOccurrences() {
        queueOccurrences = queue.map { _ in QueueOccurrenceID() }
    }
}
#endif
