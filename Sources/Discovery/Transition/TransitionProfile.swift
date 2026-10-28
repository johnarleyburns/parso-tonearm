#if !os(watchOS)
import Foundation

/// Compact per-track transition analysis kept beside the native-128 embedding. It holds beat
/// grid, cues, phrase boundaries, a coarse loudness envelope and the peak — never waveform
/// display data. Absent fields mean "not measured": a planner treats them as lower-confidence
/// fallback and nothing is fabricated for sparse-only remote work.
public struct TransitionProfile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maxPhraseBoundaries = 512
    public static let maxEnvelopePoints = 600

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

    public init(
        beatPeriodSeconds: Double? = nil, beatPhaseSeconds: Double? = nil, beatConfidence: Double = 0,
        introEndSeconds: Double? = nil, outroStartSeconds: Double? = nil,
        phraseBoundariesSeconds: [Double] = [], loudnessEnvelopeDB: [Float] = [], peak: Float = 0
    ) {
        self.beatPeriodSeconds = beatPeriodSeconds
        self.beatPhaseSeconds = beatPhaseSeconds
        self.beatConfidence = beatConfidence
        self.introEndSeconds = introEndSeconds
        self.outroStartSeconds = outroStartSeconds
        self.phraseBoundariesSeconds = phraseBoundariesSeconds
        self.loudnessEnvelopeDB = loudnessEnvelopeDB
        self.peak = peak
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
