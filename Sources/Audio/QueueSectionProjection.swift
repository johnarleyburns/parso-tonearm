#if !os(watchOS)
import Foundation

/// Pure presentation grouping of the queue by typed provenance (never by track id).
/// Only the current entry and *future* entries are projected; each future entry
/// lands in exactly one section, keyed by its physical queue offset.
public struct QueueSectionProjection: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case manual, context, keepPlaying

        public var accessibilityIdentifier: String { "np.queue.section.\(rawValue)" }
    }

    public struct Section: Equatable, Sendable {
        public let kind: Kind
        /// Physical queue offsets, in actual playback order.
        public let offsets: [Int]
    }

    /// Offset of the current entry, or nil when the queue is empty.
    public let currentOffset: Int?
    /// Non-empty future sections in render order: manual, context, keepPlaying.
    public let sections: [Section]

    public init(entries: [PlaybackQueueEntry], currentIndex: Int) {
        currentOffset = entries.indices.contains(currentIndex) ? currentIndex : nil
        var manual: [Int] = [], context: [Int] = [], keep: [Int] = []
        let start = max(currentIndex + 1, 0)
        if start < entries.count {
            for offset in start..<entries.count {
                switch entries[offset].origin {
                case .listenerNext, .listenerQueued: manual.append(offset)
                case .context: context.append(offset)
                case .keepPlaying: keep.append(offset)
                }
            }
        }
        sections = [Section(kind: .manual, offsets: manual),
                    Section(kind: .context, offsets: context),
                    Section(kind: .keepPlaying, offsets: keep)].filter { !$0.offsets.isEmpty }
    }

    public var hasManual: Bool { sections.contains { $0.kind == .manual } }
    public var hasKeepPlaying: Bool { sections.contains { $0.kind == .keepPlaying } }
}

extension AudioPlayer {
    public var queueSectionProjection: QueueSectionProjection {
        QueueSectionProjection(entries: queueEntries, currentIndex: index)
    }

    /// Removes only unplayed `.listenerNext` / `.listenerQueued` entries.
    public func removeUnplayedListenerTracks() {
        let offsets = queueEntries.enumerated().compactMap { offset, entry -> Int? in
            offset > index && (entry.origin == .listenerNext || entry.origin == .listenerQueued) ? offset : nil
        }
        guard !offsets.isEmpty else { return }
        removeFromQueue(atOffsets: IndexSet(offsets))
    }
}
#endif
