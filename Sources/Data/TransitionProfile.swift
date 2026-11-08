import Foundation

/// A compact, bounded per-track descriptor for fast blend-transition planning — beat grid, intro/
/// outro boundaries, phrase structure and a coarse loudness shape — without a waveform render or a
/// full audio decode at plan time. Stored alongside a starter/discovery row's embedding and musical
/// descriptors (one record, not an N×N precomputed transition table).
///
/// `loudnessEnvelope` is a fixed `loudnessEnvelopeBinCount`-bin, signed-byte (int8) encoding: each
/// byte is the track's loudness in that bin relative to its own peak, in 0.5 dB steps (byte value
/// `-120` through `+0`, clamped), covering the track's full duration evenly. Empty (`Data()`) means
/// no envelope was computed; any other length is invalid. `phraseBoundariesSeconds` is capped at
/// `maxPhraseBoundaries` — a profile needing more than that is not "compact" and should summarize
/// instead of enumerate.
public struct TransitionProfile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let loudnessEnvelopeBinCount = 64
    public static let maxPhraseBoundaries = 128
    /// A generous ceiling on the whole encoded (JSON) payload stored in a `transition_profile`
    /// BLOB column — comfortably above a maximal profile's real JSON size (a full 64-byte envelope
    /// plus 128 phrase boundaries encodes to well under 2 KB), just large enough to catch corrupt
    /// or pathological data before it ever reaches SQLite.
    public static let maxEncodedByteCount = 4096

    public let version: Int
    public let beatPeriodSeconds: Double?
    public let beatPhaseSeconds: Double?
    public let beatConfidence: Double
    public let introEndSeconds: Double?
    public let outroStartSeconds: Double?
    public let phraseBoundariesSeconds: [Double]
    public let loudnessEnvelope: Data
    public let peak: Float?

    public init(
        version: Int = TransitionProfile.currentVersion, beatPeriodSeconds: Double?,
        beatPhaseSeconds: Double?, beatConfidence: Double, introEndSeconds: Double?,
        outroStartSeconds: Double?, phraseBoundariesSeconds: [Double], loudnessEnvelope: Data,
        peak: Float?
    ) throws {
        guard phraseBoundariesSeconds.count <= Self.maxPhraseBoundaries else {
            throw TransitionProfileError.oversized(
                "phraseBoundariesSeconds has \(phraseBoundariesSeconds.count) entries, max \(Self.maxPhraseBoundaries)")
        }
        guard loudnessEnvelope.isEmpty || loudnessEnvelope.count == Self.loudnessEnvelopeBinCount else {
            throw TransitionProfileError.invalidEnvelope(
                "loudnessEnvelope must be empty or exactly \(Self.loudnessEnvelopeBinCount) bytes, got \(loudnessEnvelope.count)")
        }
        self.version = version
        self.beatPeriodSeconds = beatPeriodSeconds
        self.beatPhaseSeconds = beatPhaseSeconds
        self.beatConfidence = beatConfidence
        self.introEndSeconds = introEndSeconds
        self.outroStartSeconds = outroStartSeconds
        self.phraseBoundariesSeconds = phraseBoundariesSeconds
        self.loudnessEnvelope = loudnessEnvelope
        self.peak = peak
    }

    /// The bytes stored in `starter_track.transition_profile`. Throws if the encoded payload
    /// exceeds `maxEncodedByteCount` — a profile built through the throwing `init` above is
    /// already bounded, so in practice this only ever fires for a value that was somehow
    /// constructed with bounds respected but absurdly verbose optional/`Double` representations;
    /// kept as a hard backstop regardless.
    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maxEncodedByteCount else {
            throw TransitionProfileError.oversized("encoded profile is \(data.count) bytes, max \(Self.maxEncodedByteCount)")
        }
        return data
    }

    /// Decodes and re-validates: `Codable`'s synthesized `init(from:)` bypasses the throwing
    /// memberwise `init` above, so a corrupt or foreign payload could otherwise carry an
    /// out-of-bounds envelope length or phrase-boundary count straight through JSON decoding.
    public static func decode(_ data: Data) throws -> TransitionProfile {
        guard data.count <= maxEncodedByteCount else {
            throw TransitionProfileError.oversized("encoded profile is \(data.count) bytes, max \(maxEncodedByteCount)")
        }
        let decoded = try JSONDecoder().decode(TransitionProfile.self, from: data)
        return try TransitionProfile(
            version: decoded.version, beatPeriodSeconds: decoded.beatPeriodSeconds,
            beatPhaseSeconds: decoded.beatPhaseSeconds, beatConfidence: decoded.beatConfidence,
            introEndSeconds: decoded.introEndSeconds, outroStartSeconds: decoded.outroStartSeconds,
            phraseBoundariesSeconds: decoded.phraseBoundariesSeconds,
            loudnessEnvelope: decoded.loudnessEnvelope, peak: decoded.peak)
    }
}

public enum TransitionProfileError: Error, Equatable {
    case oversized(String)
    case invalidEnvelope(String)
}
