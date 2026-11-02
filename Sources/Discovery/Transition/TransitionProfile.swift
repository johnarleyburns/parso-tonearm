#if !os(watchOS)
import Foundation

/// Compact per-track transition analysis kept beside the native-128 embedding. It holds beat
/// grid, cues, phrase boundaries, a coarse loudness envelope and the peak — never waveform
/// display data. Absent fields mean "not measured": a planner treats them as lower-confidence
/// fallback and nothing is fabricated for sparse-only remote work.
public struct TransitionProfile: Codable, Equatable, Sendable {
    /// v1: beat grid + cues + plain phrase-boundary timestamps (`ProfileTransitionPlanner`).
    /// v2 (additive): also carries real drop/bass-exit timestamps and the bar phase they snap to
    /// (`ParsoAudioAnalysis.DropDetector`, `Domain/Mix/DropAwareEdgePlanner`) — enough to plan a
    /// genuine `.doubleDrop`/`.bassSwap`/`.phraseCut` edge, not just a crossfade. A v1 payload
    /// decodes fine with the new fields absent/empty; nothing that reads only v1 fields changes.
    public static let currentVersion = 2
    public static let maxPhraseBoundaries = 512
    public static let maxEnvelopePoints = 600
    public static let maxDropOrExitPoints = 64

    public enum ValidationError: Error, Equatable, Sendable {
        case nonFinite(String)
        case outOfRange(String)
        case tooLarge(String)
        case cuesOutOfOrder
    }

    public var beatPeriodSeconds: Double?
    public var beatPhaseSeconds: Double?
    public var beatConfidence: Double
    public var introEndSeconds: Double?
    public var outroStartSeconds: Double?
    public var phraseBoundariesSeconds: [Double]
    public var loudnessEnvelopeDB: [Float]
    public var peak: Float
    /// v2: the beat-grid phase (0...3 beats) most drops/bass-exits share, for re-snapping a beat
    /// index to the same bar alignment `DropAwareTrackStructure.detect` used. Nil when v1 or
    /// unmeasured.
    public var barPhase: Int?
    /// v2: the bar-aligned beat phase (0...31 beats) where 8-bar phrases start — where
    /// `DropAwareEdgePlanner` looks for a phrase-line swap point when no drop/exit qualifies.
    public var phrasePhase: Int?
    /// v2: real drop timestamps (the bass returning), bar-phase-snapped. Never invented — empty
    /// means none were found, not that none exist.
    public var dropSeconds: [Double]
    /// v2: real bass-exit timestamps (a breakdown or the outro starting), same snapping.
    public var exitSeconds: [Double]
    /// v2: whether the track's bass is already present near its start (no intro to wait for) —
    /// the one scalar `DropAwareTrackStructure.bassPresentFromStart` needs from the full kick-band
    /// curve, kept instead of the curve itself to stay compact. Nil when unmeasured.
    public var bassPresentFromStart: Bool?

    public init(
        beatPeriodSeconds: Double? = nil, beatPhaseSeconds: Double? = nil, beatConfidence: Double = 0,
        introEndSeconds: Double? = nil, outroStartSeconds: Double? = nil,
        phraseBoundariesSeconds: [Double] = [], loudnessEnvelopeDB: [Float] = [], peak: Float = 0,
        barPhase: Int? = nil, phrasePhase: Int? = nil, dropSeconds: [Double] = [],
        exitSeconds: [Double] = [], bassPresentFromStart: Bool? = nil
    ) {
        self.beatPeriodSeconds = beatPeriodSeconds
        self.beatPhaseSeconds = beatPhaseSeconds
        self.beatConfidence = beatConfidence
        self.introEndSeconds = introEndSeconds
        self.outroStartSeconds = outroStartSeconds
        self.phraseBoundariesSeconds = phraseBoundariesSeconds
        self.loudnessEnvelopeDB = loudnessEnvelopeDB
        self.peak = peak
        self.barPhase = barPhase
        self.phrasePhase = phrasePhase
        self.dropSeconds = dropSeconds
        self.exitSeconds = exitSeconds
        self.bassPresentFromStart = bassPresentFromStart
    }

    /// Decodes a payload written before the v2 fields existed with them absent/empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        beatPeriodSeconds = try c.decodeIfPresent(Double.self, forKey: .beatPeriodSeconds)
        beatPhaseSeconds = try c.decodeIfPresent(Double.self, forKey: .beatPhaseSeconds)
        beatConfidence = try c.decode(Double.self, forKey: .beatConfidence)
        introEndSeconds = try c.decodeIfPresent(Double.self, forKey: .introEndSeconds)
        outroStartSeconds = try c.decodeIfPresent(Double.self, forKey: .outroStartSeconds)
        phraseBoundariesSeconds = try c.decode([Double].self, forKey: .phraseBoundariesSeconds)
        loudnessEnvelopeDB = try c.decode([Float].self, forKey: .loudnessEnvelopeDB)
        peak = try c.decode(Float.self, forKey: .peak)
        barPhase = try c.decodeIfPresent(Int.self, forKey: .barPhase)
        phrasePhase = try c.decodeIfPresent(Int.self, forKey: .phrasePhase)
        dropSeconds = try c.decodeIfPresent([Double].self, forKey: .dropSeconds) ?? []
        exitSeconds = try c.decodeIfPresent([Double].self, forKey: .exitSeconds) ?? []
        bassPresentFromStart = try c.decodeIfPresent(Bool.self, forKey: .bassPresentFromStart)
    }

    public func validate() throws {
        let optionals: [(String, Double?)] = [
            ("beatPeriod", beatPeriodSeconds), ("beatPhase", beatPhaseSeconds),
            ("introEnd", introEndSeconds), ("outroStart", outroStartSeconds),
        ]
        for (name, value) in optionals {
            guard let value else { continue }
            guard value.isFinite else { throw ValidationError.nonFinite(name) }
            guard value >= 0 else { throw ValidationError.outOfRange(name) }
        }
        if let period = beatPeriodSeconds, period <= 0 { throw ValidationError.outOfRange("beatPeriod") }
        guard beatConfidence.isFinite else { throw ValidationError.nonFinite("beatConfidence") }
        guard (0...1).contains(beatConfidence) else { throw ValidationError.outOfRange("beatConfidence") }
        guard peak.isFinite else { throw ValidationError.nonFinite("peak") }
        guard (0...1).contains(peak) else { throw ValidationError.outOfRange("peak") }
        guard phraseBoundariesSeconds.count <= Self.maxPhraseBoundaries else {
            throw ValidationError.tooLarge("phraseBoundaries")
        }
        guard phraseBoundariesSeconds.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ValidationError.nonFinite("phraseBoundaries")
        }
        guard loudnessEnvelopeDB.count <= Self.maxEnvelopePoints else {
            throw ValidationError.tooLarge("loudnessEnvelope")
        }
        guard loudnessEnvelopeDB.allSatisfy({ $0.isFinite }) else {
            throw ValidationError.nonFinite("loudnessEnvelope")
        }
        if let intro = introEndSeconds, let outro = outroStartSeconds, intro > outro {
            throw ValidationError.cuesOutOfOrder
        }
        if let barPhase { guard (0..<4).contains(barPhase) else { throw ValidationError.outOfRange("barPhase") } }
        if let phrasePhase {
            guard (0..<32).contains(phrasePhase) else { throw ValidationError.outOfRange("phrasePhase") }
        }
        guard dropSeconds.count <= Self.maxDropOrExitPoints, exitSeconds.count <= Self.maxDropOrExitPoints else {
            throw ValidationError.tooLarge("dropOrExit")
        }
        guard dropSeconds.allSatisfy({ $0.isFinite && $0 >= 0 }),
              exitSeconds.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ValidationError.nonFinite("dropOrExit")
        }
    }

    /// Validated JSON payload for `discovery_transition_profile.payload`.
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> TransitionProfile {
        let profile = try JSONDecoder().decode(TransitionProfile.self, from: data)
        try profile.validate()
        return profile
    }
}
#endif
