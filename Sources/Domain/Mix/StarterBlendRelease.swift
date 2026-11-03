import Foundation

/// Facts the blender needs about a track, from the release's analysis. Time is source seconds;
/// beat `k` of the grid is at `beatPhase + k * beatPeriod`.
public struct StarterTrackFacts: Codable, Sendable, Equatable {
    public let id: String
    public let durationSeconds: Double
    public let bpm: Double
    public let beatPeriod: Double
    public let beatPhase: Double
    public let rmsDB: Double

    public init(id: String, durationSeconds: Double, bpm: Double, beatPeriod: Double, beatPhase: Double,
                rmsDB: Double) {
        self.id = id
        self.durationSeconds = durationSeconds
        self.bpm = bpm
        self.beatPeriod = beatPeriod
        self.beatPhase = beatPhase
        self.rmsDB = rmsDB
    }

    public func beatTime(_ beat: Int) -> Double { beatPhase + Double(beat) * beatPeriod }
}

@available(*, deprecated, renamed: "BlendEdgePlan")
public typealias StarterEdgePlan = BlendEdgePlan

/// A concrete, immutable plan for any directed blend edge (fixed, saved or catalog-derived). Playback
/// executes these values directly; nothing here re-derives or guesses a plan at render time.
public struct BlendEdgePlan: Codable, Sendable, Equatable {
    public enum Style: String, Codable, Sendable, Equatable {
        case bassSwap = "bass-swap"
        case doubleDrop = "double-drop"
        case phraseCut = "phrase-cut"
    }

    public let blendID: String
    /// 1-based edge number within the blend (edge 1 joins track 1 → 2).
    public let edge: Int
    public let outgoingTrackID: String
    public let incomingTrackID: String
    public let style: Style
    /// Incoming playback rate relative to its native tempo (matches its BPM to the outgoing's).
    public let tempo: Double
    public let overlapBeats: Int
    public var incomingGain: Double? = nil
    public var outgoingSwapBeat: Int? = nil
    public var incomingSwapBeat: Int? = nil
    /// Outgoing source seconds at which the incoming deck becomes audible.
    public var blendStartSeconds: Double? = nil
    public var swapSeconds: Double? = nil
    public var blendEndSeconds: Double? = nil
    /// Outgoing-timeline second at which the incoming track's own time 0 plays: the incoming
    /// source position at outgoing time `T` is `(T - incomingOffsetSeconds) * tempo`.
    public var incomingOffsetSeconds: Double? = nil
    /// Phrase cut: outgoing source second of the cut and incoming source second it lands on.
    public var outgoingStartSeconds: Double? = nil
    public var incomingStartSeconds: Double? = nil

    /// What the renderer needs, all in source seconds of each track.
    public struct Schedule: Equatable, Sendable {
        public let style: Style
        /// Outgoing source second where the incoming becomes audible.
        public let outgoingStart: Double
        /// Overlap length in outgoing seconds (0 for a cut).
        public let overlapSeconds: Double
        /// Seconds into the overlap where the bass swaps (nil: no swap).
        public let swapOffsetSeconds: Double?
        /// Incoming source second playing when the overlap starts.
        public let incomingStart: Double
        public let incomingTempo: Double
        public let incomingGain: Double
    }

    /// Resolves the plan from its own stored values. Nil when the plan lacks the values its
    /// style needs (a malformed plan is never silently replaced by a guess).
    public func schedule() -> Schedule? {
        switch style {
        case .phraseCut:
            guard let cut = outgoingStartSeconds, let start = incomingStartSeconds else { return nil }
            return Schedule(style: style, outgoingStart: cut, overlapSeconds: 0,
                            swapOffsetSeconds: nil, incomingStart: start,
                            incomingTempo: tempo, incomingGain: incomingGain ?? 1)
        case .bassSwap, .doubleDrop:
            guard let start = blendStartSeconds, let end = blendEndSeconds, let swap = swapSeconds,
                  let offset = incomingOffsetSeconds, end > start else { return nil }
            return Schedule(style: style, outgoingStart: start, overlapSeconds: end - start,
                            swapOffsetSeconds: min(max(swap - start, 0), end - start),
                            incomingStart: max(0, (start - offset) * tempo), incomingTempo: tempo,
                            incomingGain: incomingGain ?? 1)
        }
    }
}
