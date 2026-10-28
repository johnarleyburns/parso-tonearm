#if !os(watchOS)
import Foundation
import CryptoKit
import TonearmCore

/// Per-track inputs to the profile-driven planner: existing BPM/key/energy plus the compact
/// `TransitionProfile`. A track owns only this; no pair is ever precomputed or stored.
public struct TrackTransitionFeatures: Sendable, Equatable {
    public let trackID: Int64
    /// Identity of the audio asset version the profile was measured from.
    public let assetRevision: String
    public let durationSeconds: TimeInterval
    public let bpm: Double?
    public let key: String?
    public let energy: Double?
    public let profile: TransitionProfile?

    public init(trackID: Int64, assetRevision: String, durationSeconds: TimeInterval, bpm: Double? = nil,
                key: String? = nil, energy: Double? = nil, profile: TransitionProfile? = nil) {
        self.trackID = trackID
        self.assetRevision = assetRevision
        self.durationSeconds = durationSeconds
        self.bpm = bpm
        self.key = key
        self.energy = energy
        self.profile = profile
    }
}

public struct ProfileTransitionPlanInput: Sendable, Equatable {
    public let outgoing: TrackTransitionFeatures
    public let incoming: TrackTransitionFeatures
    public let requestedDuration: TimeInterval

    public init(outgoing: TrackTransitionFeatures, incoming: TrackTransitionFeatures,
                requestedDuration: TimeInterval) {
        self.outgoing = outgoing
        self.incoming = incoming
        self.requestedDuration = requestedDuration
    }
}

public enum ProfileTransitionPlanQuality: String, Sendable, Equatable {
    case phraseAlignedBeatMatched
    case beatMatched
    case energyCrossfadeFallback
}

public struct ProfileTransitionPlan: Sendable, Equatable {
    public let quality: ProfileTransitionPlanQuality
    public let outgoingStart: TimeInterval
    public let incomingStart: TimeInterval
    public let duration: TimeInterval
    /// Playback rate applied to the incoming track; nil unless a beat grid was matched.
    public let tempoRatio: Double?
    /// Bounded keys (`ProfileTransitionPlanner.Reason` raw values); no audio-derived data.
    public let explanation: [String]
}

public protocol ProfileTransitionPlanning: Sendable {
    func makePlan(_ input: ProfileTransitionPlanInput) throws -> ProfileTransitionPlan
}

/// Pure, deterministic planner. Decision ladder:
/// 1. Both beat grids confident, tempo within `maxTempoDelta`, and both tracks have phrase
///    cues that fit the duration → `phraseAlignedBeatMatched` (phrase boundaries, snapped to beats).
/// 2. Both beat grids confident and compatible, phrase cues absent/unusable → `beatMatched`
///    (outro/tail and track start snapped to the nearest beat phase).
/// 3. Anything else → `energyCrossfadeFallback`: bounded positions from duration and the outro
///    cue, `tempoRatio` nil, no phase inferred.
public struct ProfileTransitionPlanner: ProfileTransitionPlanning {
    public struct Configuration: Sendable, Equatable {
        /// Bump when the decision logic changes; part of the cache key.
        public static let version = 1
        /// Safe playback tempo window: incoming rate must be within 1 ± this.
        public var maxTempoDelta = 0.06
        public var minBeatConfidence = 0.6
        public var minDuration: TimeInterval = 1
        public init() {}
    }

    public enum Reason: String, Sendable {
        case phraseAligned, beatPhaseAligned
        case outgoingBeatLow, incomingBeatLow
        case outgoingProfileMissing, incomingProfileMissing
        case outgoingProfileInvalid, incomingProfileInvalid
        case tempoOutOfRange, phraseCuesUnusable, beatSnapOutOfBounds
        case envelopeMissing, durationClamped
    }

    public enum PlanError: Error, Equatable, Sendable {
        case invalidDuration
        case invalidTrackDuration
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func makePlan(_ input: ProfileTransitionPlanInput) throws -> ProfileTransitionPlan {
        let out = input.outgoing, inc = input.incoming
        guard input.requestedDuration.isFinite, input.requestedDuration > 0 else { throw PlanError.invalidDuration }
        guard out.durationSeconds.isFinite, out.durationSeconds > 0,
              inc.durationSeconds.isFinite, inc.durationSeconds > 0 else { throw PlanError.invalidTrackDuration }

        var reasons: [Reason] = []
        let limit = min(out.durationSeconds, inc.durationSeconds)
        let duration = min(input.requestedDuration, limit)
        if duration < input.requestedDuration { reasons.append(.durationClamped) }

        let outProfile = usable(out.profile, side: "outgoing", reasons: &reasons)
        let incProfile = usable(inc.profile, side: "incoming", reasons: &reasons)
        if outProfile?.loudnessEnvelopeDB.isEmpty != false || incProfile?.loudnessEnvelopeDB.isEmpty != false {
            reasons.append(.envelopeMissing)
        }

        if let o = outProfile, let i = incProfile,
           let ratio = beatRatio(o, i, reasons: &reasons),
           let oGrid = grid(o), let iGrid = grid(i) {
            // Incoming plays `ratio`× faster, consuming `duration * ratio` source seconds.
            let incomingSpan = duration * ratio
            let outHi = out.durationSeconds - duration
            let inHi = inc.durationSeconds - incomingSpan
            if inHi >= 0, outHi >= 0 {
                let target = clamp(o.outroStartSeconds ?? outHi, 0, outHi)
                if let phrase = phraseStarts(o, i, target: target, outHi: outHi, inHi: inHi),
                   let os = snap(phrase.out, oGrid, 0, outHi), let isn = snap(phrase.inc, iGrid, 0, inHi) {
                    return ProfileTransitionPlan(
                        quality: .phraseAlignedBeatMatched, outgoingStart: os, incomingStart: isn,
                        duration: duration, tempoRatio: ratio,
                        explanation: (reasons + [.phraseAligned, .beatPhaseAligned]).map(\.rawValue))
                }
                if let os = snap(target, oGrid, 0, outHi), let isn = snap(0, iGrid, 0, inHi) {
                    return ProfileTransitionPlan(
                        quality: .beatMatched, outgoingStart: os, incomingStart: isn,
                        duration: duration, tempoRatio: ratio,
                        explanation: (reasons + [.phraseCuesUnusable, .beatPhaseAligned]).map(\.rawValue))
                }
                reasons.append(.beatSnapOutOfBounds)
            }
        }

        let outHi = max(0, out.durationSeconds - duration)
        let start = clamp(outProfile?.outroStartSeconds ?? outHi, 0, outHi)
        return ProfileTransitionPlan(
            quality: .energyCrossfadeFallback, outgoingStart: start, incomingStart: 0,
            duration: duration, tempoRatio: nil, explanation: reasons.map(\.rawValue))
    }

    // MARK: - Helpers

    private func usable(_ profile: TransitionProfile?, side: String, reasons: inout [Reason]) -> TransitionProfile? {
        let outgoing = side == "outgoing"
        guard let profile else {
            reasons.append(outgoing ? .outgoingProfileMissing : .incomingProfileMissing)
            return nil
        }
        guard (try? profile.validate()) != nil else {
            reasons.append(outgoing ? .outgoingProfileInvalid : .incomingProfileInvalid)
            return nil
        }
        return profile
    }

    private func grid(_ p: TransitionProfile) -> (period: Double, phase: Double)? {
        guard let period = p.beatPeriodSeconds, let phase = p.beatPhaseSeconds, period > 0 else { return nil }
        return (period, phase)
    }

    /// The incoming tempo ratio when both grids are confident and compatible, else nil.
    private func beatRatio(_ o: TransitionProfile, _ i: TransitionProfile, reasons: inout [Reason]) -> Double? {
        var ok = true
        if o.beatConfidence < configuration.minBeatConfidence || grid(o) == nil {
            reasons.append(.outgoingBeatLow); ok = false
        }
        if i.beatConfidence < configuration.minBeatConfidence || grid(i) == nil {
            reasons.append(.incomingBeatLow); ok = false
        }
        guard ok, let op = o.beatPeriodSeconds, let ip = i.beatPeriodSeconds else { return nil }
        // Speeding the incoming track by ip/op makes its period equal the outgoing one.
        let ratio = ip / op
        guard abs(ratio - 1) <= configuration.maxTempoDelta + 1e-12 else {
            reasons.append(.tempoOutOfRange); return nil
        }
        return ratio
    }

    /// Outgoing phrase boundary nearest the target and the incoming's earliest usable boundary.
    private func phraseStarts(_ o: TransitionProfile, _ i: TransitionProfile, target: Double,
                              outHi: Double, inHi: Double) -> (out: Double, inc: Double)? {
        let outs = o.phraseBoundariesSeconds.filter { $0 >= 0 && $0 <= outHi }
        let incs = i.phraseBoundariesSeconds.filter { $0 >= 0 && $0 <= inHi }
        guard let po = outs.min(by: { (abs($0 - target), $0) < (abs($1 - target), $1) }),
              let pi = incs.min() else { return nil }
        return (po, pi)
    }

    /// Nearest beat to `t`, moved by whole periods into `[lo, hi]`; nil when no beat fits.
    private func snap(_ t: Double, _ g: (period: Double, phase: Double), _ lo: Double, _ hi: Double) -> Double? {
        var v = g.phase + ((t - g.phase) / g.period).rounded() * g.period
        if v > hi { v -= ((v - hi) / g.period).rounded(.up) * g.period }
        if v < lo { v += ((lo - v) / g.period).rounded(.up) * g.period }
        return v >= lo - 1e-9 && v <= hi + 1e-9 ? min(max(v, lo), hi) : nil
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    // MARK: - Cache identity

    /// The cache context for `input`: revisions, profile content digests, duration, config and
    /// embedding-space fingerprint. Nothing is hashed from audio.
    public static func cacheContext(for input: ProfileTransitionPlanInput,
                                    embeddingSpaceFingerprint: String) -> BlendPlanCache.ProfileContext {
        .init(outgoingAssetRevision: input.outgoing.assetRevision,
              incomingAssetRevision: input.incoming.assetRevision,
              outgoingProfileDigest: digest(input.outgoing.profile),
              incomingProfileDigest: digest(input.incoming.profile),
              requestedDurationMillis: Int64((input.requestedDuration * 1000).rounded()),
              plannerConfigVersion: Configuration.version,
              embeddingSpaceFingerprint: embeddingSpaceFingerprint)
    }

    static func digest(_ profile: TransitionProfile?) -> String {
        guard let profile else { return "none" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(profile) else { return "unencodable" }
        return "v\(TransitionProfile.currentVersion):"
            + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
