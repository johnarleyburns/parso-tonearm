import Foundation

/// Identity of one queue edge: the outgoing occurrence's position plus both track IDs.
/// The same track queued twice yields distinct keys, and any reorder/delete that changes
/// a neighbour changes the key, so a cached card can never be mistaken for the new edge.
public struct QueueEdgeKey: Hashable, Sendable {
    public let position: Int
    public let fromTrackID: Int64?
    public let toTrackID: Int64?
    /// Stable queue-slot identities of both ends; they survive reorder/delete, unlike `position`.
    public let fromOccurrence: QueueOccurrenceID?
    public let toOccurrence: QueueOccurrenceID?
    public init(position: Int, fromTrackID: Int64?, toTrackID: Int64?,
                fromOccurrence: QueueOccurrenceID? = nil, toOccurrence: QueueOccurrenceID? = nil) {
        self.position = position
        self.fromTrackID = fromTrackID
        self.toTrackID = toTrackID
        self.fromOccurrence = fromOccurrence
        self.toOccurrence = toOccurrence
    }

    /// The renderer's key for this edge; nil when the queue slots carry no occurrence identity.
    public var executionKey: TransitionEdgeKey? {
        guard let fromOccurrence, let toOccurrence else { return nil }
        return TransitionEdgeKey(from: fromOccurrence, to: toOccurrence)
    }
}

/// One outgoing edge shown under a queue occurrence.
public struct QueueEdgeRow: Sendable, Equatable, Identifiable {
    public let key: QueueEdgeKey
    public let presentation: TransitionPresentation
    /// Why the edge has no blend plan when that is a queue-level fact (settings, repeat, loop).
    public let reason: String?
    /// The renderer's immutable record of exactly this occurrence pair, when one was emitted.
    public let snapshot: TransitionExecutionSnapshot?
    /// True while this edge is the one audibly blending (overlap or outgoing tail).
    public let isActive: Bool
    /// The listener asked for this edge to play without a blend.
    public let playsWithoutBlend: Bool
    public var id: QueueEdgeKey { key }

    public init(key: QueueEdgeKey, presentation: TransitionPresentation, reason: String?,
                snapshot: TransitionExecutionSnapshot? = nil, isActive: Bool = false,
                playsWithoutBlend: Bool = false) {
        self.key = key
        self.presentation = presentation
        self.reason = reason
        self.snapshot = snapshot
        self.isActive = isActive
        self.playsWithoutBlend = playsWithoutBlend
    }

    /// Safe to retry: the renderer denied or cancelled this exact edge.
    public var canRetry: Bool {
        guard let phase = snapshot?.phase else { return false }
        return phase == .denied || phase == .cancelled
    }
    /// A blend is planned or running that "Play without blend" can still replace.
    public var canPlayWithoutBlend: Bool {
        guard key.executionKey != nil, !playsWithoutBlend, !isActive else { return false }
        return snapshot?.isTerminal != true
    }

    public var timeline: QueueEdgeTimeline { QueueEdgeTimeline(presentation) }
    public var summary: String { reason ?? timeline.summary }
    public var accessibilityLabel: String {
        reason.map { String(localized: "Transition", bundle: .module) + ", " + $0 } ?? timeline.accessibilityLabel
    }
}

/// Builds the per-edge rows for the Queue from the live engine presentation. Live state is
/// attached only to the edge whose track IDs it names; every other edge is "planned when up next".
public enum QueueEdgeResolver {
    public static func rows(trackIDs: [Int64?], currentIndex: Int, repeatMode: RepeatMode,
                            smartBlendEnabled: Bool, live: TransitionPresentation,
                            occurrences: [QueueOccurrenceID] = [],
                            snapshot: (Int) -> TransitionExecutionSnapshot? = { _ in nil },
                            noBlend: Set<TransitionEdgeKey> = []) -> [QueueEdgeRow] {
        guard !trackIDs.isEmpty else { return [] }
        let last = trackIDs.count - 1
        // During an outgoing tail the live A→B edge belongs to the previous occurrence.
        let liveIndex = live.phase == .outgoingTail ? currentIndex - 1 : currentIndex
        var rows: [QueueEdgeRow] = []
        for i in 0...last {
            let loops = i == last && repeatMode == .all && trackIDs.count > 1
            if i == last && !loops { continue } // end of queue: no outgoing edge
            let next = loops ? 0 : i + 1
            let hasOccurrences = occurrences.count == trackIDs.count
            let key = QueueEdgeKey(position: i, fromTrackID: trackIDs[i], toTrackID: trackIDs[next],
                                   fromOccurrence: hasOccurrences ? occurrences[i] : nil,
                                   toOccurrence: hasOccurrences ? occurrences[next] : nil)
            let edgeSnapshot = key.executionKey.flatMap { _ in snapshot(i) }
            let skipsBlend = key.executionKey.map(noBlend.contains) ?? false
            var presentation = TransitionPresentation(phase: .notPlanned)
            var reason: String?
            var isActive = false
            if skipsBlend {
                reason = String(localized: "Playing without a blend", bundle: .module)
            } else if !smartBlendEnabled {
                reason = String(localized: "Smart transitions are off", bundle: .module)
            } else if repeatMode == .one && i == currentIndex {
                reason = String(localized: "Repeating this track", bundle: .module)
            } else if i == liveIndex, live.phase != .noEdge, matches(live, key) {
                if live.phase == .fallback, let edgeSnapshot,
                   edgeSnapshot.phase != .denied, edgeSnapshot.phase != .cancelled,
                   edgeSnapshot.executedStyle?.overlaps == true {
                    presentation = Self.presentation(of: edgeSnapshot, key: key)
                    isActive = edgeSnapshot.phase == .overlapping || edgeSnapshot.phase == .handedOff
                } else {
                    presentation = live.applying(edgeSnapshot)
                    isActive = live.phase == .overlap || live.phase == .outgoingTail
                }
            } else if let edgeSnapshot {
                presentation = Self.presentation(of: edgeSnapshot, key: key)
            } else if loops {
                reason = String(localized: "Loops back to the first track", bundle: .module)
            }
            rows.append(QueueEdgeRow(key: key, presentation: presentation, reason: reason,
                                     snapshot: edgeSnapshot, isActive: isActive, playsWithoutBlend: skipsBlend))
        }
        return rows
    }

    /// The row of the queue that `selected` still names, or nil once it is gone. Occurrence
    /// identity wins over position, so a reorder keeps the selection on the same pair while a
    /// delete, replacement or neighbour change drops it; a duplicate never inherits it.
    public static func resolve(_ selected: QueueEdgeKey?, in rows: [QueueEdgeRow]) -> QueueEdgeRow? {
        guard let selected else { return nil }
        guard selected.executionKey != nil else { return rows.first { $0.key == selected } }
        return rows.first {
            $0.key.fromOccurrence == selected.fromOccurrence && $0.key.toOccurrence == selected.toOccurrence
                && $0.key.fromTrackID == selected.fromTrackID && $0.key.toTrackID == selected.toTrackID
        }
    }

    /// What a renderer snapshot says about an edge that is not the live one.
    private static func presentation(of snapshot: TransitionExecutionSnapshot, key: QueueEdgeKey) -> TransitionPresentation {
        var result = TransitionPresentation(
            phase: .fallback, plannedStyle: snapshot.plannedStyle ?? snapshot.requestedStyle,
            actualStyle: snapshot.executedStyle, outgoingTrackID: key.fromTrackID, incomingTrackID: key.toTrackID,
            preparation: snapshot.readiness, executionReason: snapshot.reason)
        switch snapshot.phase {
        case .denied, .cancelled:
            result.actualStyle = nil
        default:
            if snapshot.executedStyle?.overlaps != false {
                if case .ready = snapshot.readiness { result.phase = .ready } else { result.phase = .preparing }
            }
        }
        return result
    }

    private static func matches(_ live: TransitionPresentation, _ key: QueueEdgeKey) -> Bool {
        (live.outgoingTrackID == nil || live.outgoingTrackID == key.fromTrackID)
            && (live.incomingTrackID == nil || live.incomingTrackID == key.toTrackID)
    }
}
