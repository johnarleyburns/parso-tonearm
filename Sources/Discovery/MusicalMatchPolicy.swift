#if !os(watchOS)
import Foundation
import ParsoAudioAnalysis

/// The explicit DJ compatibility gate shared by mood, Keep Playing, and
/// Find Music. This is intentionally separate from the softer hybrid score:
/// selecting "matching tracks" means a track either qualifies or it does not.
public struct MusicalMatchReference: Sendable, Equatable {
    public let bpm: Double
    public let camelot: CamelotKey

    public init(bpm: Double, camelot: CamelotKey) {
        self.bpm = bpm
        self.camelot = camelot
    }
}

public enum MusicalMatchPolicy {
    public static let bpmToleranceRatio = 0.08

    public static func compatibleKeys(for reference: CamelotKey) -> Set<CamelotKey> {
        Camelot.compatible(reference)
    }

    public static func compatibleKeyCodes(for reference: CamelotKey) -> Set<String> {
        Set(compatibleKeys(for: reference).map(\.code))
    }

    public static func bpmRange(for referenceBPM: Double) -> ClosedRange<Double>? {
        guard referenceBPM.isFinite, referenceBPM > 0 else { return nil }
        let delta = referenceBPM * bpmToleranceRatio
        return (referenceBPM - delta)...(referenceBPM + delta)
    }

    public static func bpmDifferenceRatio(candidate: Double, reference: Double) -> Double? {
        guard candidate.isFinite, candidate > 0,
              reference.isFinite, reference > 0 else { return nil }
        return abs(candidate / reference - 1)
    }

    public static func matches(
        candidateBPM: Double?, candidateKey: CamelotKey?, reference: MusicalMatchReference
    ) -> Bool {
        guard let candidateBPM, let candidateKey,
              let ratio = bpmDifferenceRatio(candidate: candidateBPM, reference: reference.bpm)
        else { return false }
        return ratio <= bpmToleranceRatio + 0.0000001
            && compatibleKeys(for: reference.camelot).contains(candidateKey)
    }
}
#endif
