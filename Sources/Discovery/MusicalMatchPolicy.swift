#if !os(watchOS)
import Foundation
import ParsoAudioAnalysis
import TonearmCore

/// The explicit DJ compatibility gate shared by mood, Keep Playing, and
/// Find Music. This is intentionally separate from the softer hybrid score:
/// selecting "matching tracks" means a track either qualifies or it does not.
public struct MusicalMatchReference: Sendable, Equatable {
    public let bpm: Double
    public let camelot: CamelotKey
    /// Optional: when either side of a comparison lacks an energy value, the
    /// energy gate simply never blocks a match — it's additive, not required.
    public let energy: Double?

    public init(bpm: Double, camelot: CamelotKey, energy: Double? = nil) {
        self.bpm = bpm
        self.camelot = camelot
        self.energy = energy
    }
}

public enum MusicalMatchPolicy {
    /// Preserve mood ranking while making every consecutive queue transition
    /// satisfy the same hard BPM/key/energy gate as matching search and Keep
    /// Playing. `energyByID` is optional per track — tracks with no energy
    /// value are never excluded on that basis.
    public static func queueTrackIDs(_ ids: [Int64], metadata: [Int64: DJLoadTrackInfo],
                                     energyByID: [Int64: Double] = [:],
                                     startingFrom referenceID: Int64? = nil) -> [Int64] {
        func reference(_ id: Int64) -> MusicalMatchReference? {
            guard let info = metadata[id], let bpm = info.bpm, bpm.isFinite, bpm > 0,
                  let code = info.camelotKey, let key = CamelotKey(code: code) else { return nil }
            return .init(bpm: bpm, camelot: key, energy: energyByID[id])
        }
        var previous = referenceID.flatMap(reference)
        var seen: Set<Int64> = []
        var queue: [Int64] = []
        for id in ids where seen.insert(id).inserted {
            guard let candidate = reference(id) else { continue }
            if let previous, !matches(
                candidateBPM: candidate.bpm, candidateKey: candidate.camelot,
                candidateEnergy: candidate.energy, reference: previous
            ) { continue }
            queue.append(id)
            previous = candidate
        }
        return queue
    }
    public static let bpmToleranceRatio = 0.08
    /// The analysis energy scale is 0...10 (`ParsoAudioNeural.HybridRanker`);
    /// this is the widest gap still treated as "compatible energy."
    public static let energyToleranceAbsolute = 2.0

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

    /// Nil-safe: missing energy on either side never blocks a match — only a
    /// real gap on both known values does.
    public static func energyCompatible(_ candidate: Double?, _ reference: Double?) -> Bool {
        guard let candidate, candidate.isFinite, let reference, reference.isFinite else { return true }
        return abs(candidate - reference) <= energyToleranceAbsolute
    }

    public static func matches(
        candidateBPM: Double?, candidateKey: CamelotKey?, candidateEnergy: Double? = nil,
        reference: MusicalMatchReference
    ) -> Bool {
        guard let candidateBPM, let candidateKey,
              let ratio = bpmDifferenceRatio(candidate: candidateBPM, reference: reference.bpm)
        else { return false }
        return ratio <= bpmToleranceRatio + 0.0000001
            && compatibleKeys(for: reference.camelot).contains(candidateKey)
            && energyCompatible(candidateEnergy, reference.energy)
    }
}
#endif
