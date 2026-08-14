import Foundation

// MARK: - §37.4 event timeline (plan 5.12)

/// One "a track started playing on a deck" event captured while recording
/// (§37.4): which track, which deck, and where in the mix it happened.
/// `trackID` is the DJ-library row; the title/artist/BPM/key snapshots are
/// resolved from it at finalize — the `mix_track_event` rows carry the
/// snapshots so the timeline survives track deletion (§15.5).
public struct MixTimelineEntry: Sendable, Equatable {
    public let trackID: Int64
    /// `"A"` or `"B"` — the `mix_track_event.deck` column's shape.
    public let deck: String
    /// Seconds into the mix when the track started. The recording's frames are
    /// exactly the master-clock frames the tap captured (§37.2), so the offset
    /// is `(masterSample − recordingStart) / sampleRate`.
    public let startOffsetSec: Double

    public init(trackID: Int64, deck: String, startOffsetSec: Double) {
        self.trackID = trackID
        self.deck = deck
        self.startOffsetSec = startOffsetSec
    }
}

/// The §37.4 timeline accumulated control-side during a recording (plan 5.12,
/// decision 8 — the side-car actor writes the rows, never the render thread).
/// A pure value: `WorkspaceModel` records entries as decks begin playing and
/// hands the whole timeline to `RecordingService.finalize`, which writes the
/// `mix_track_event` rows and the `mix.trackCount` in the journal's one
/// transaction (NFR-REL-1).
public struct MixTimeline: Sendable, Equatable {
    /// Consecutive re-starts of the same track on the same deck within this
    /// window are a pause/blip, not a new event — a genuine replay after the
    /// window is a real "played" and is logged (§37.4's "which tracks played
    /// and when").
    public static let duplicateSuppressionSeconds: TimeInterval = 10

    public private(set) var entries: [MixTimelineEntry]

    public init(entries: [MixTimelineEntry] = []) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Record a track start, suppressing a same-deck same-track re-log within
    /// `duplicateSuppressionSeconds` (a pause/resume blip is not a second play).
    public mutating func record(trackID: Int64, deck: String, startOffsetSec: Double) {
        if let last = entries.last,
           last.deck == deck, last.trackID == trackID,
           startOffsetSec - last.startOffsetSec < Self.duplicateSuppressionSeconds {
            return
        }
        entries.append(MixTimelineEntry(trackID: trackID, deck: deck,
                                        startOffsetSec: startOffsetSec))
    }
}
