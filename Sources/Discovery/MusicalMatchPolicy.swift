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

    public init(bpm: Double, camelot: CamelotKey) {
        self.bpm = bpm
        self.camelot = camelot
    }
}

public enum MusicalMatchPolicy {
    /// Preserve mood ranking while making every consecutive queue transition
    /// satisfy the same hard BPM/key gate as matching search and Keep Playing.
    public static func queueTrackIDs(_ ids: [Int64], metadata: [Int64: DJLoadTrackInfo],
                                     startingFrom referenceID: Int64? = nil) -> [Int64] {
        func reference(_ id: Int64) -> MusicalMatchReference? {
            guard let info = metadata[id], let bpm = info.bpm, bpm.isFinite, bpm > 0,
                  let code = info.camelotKey, let key = CamelotKey(code: code) else { return nil }
            return .init(bpm: bpm, camelot: key)
        }
        var previous = referenceID.flatMap(reference)
        var seen: Set<Int64> = []
        var queue: [Int64] = []
        for id in ids where seen.insert(id).inserted {
            guard let candidate = reference(id) else { continue }
            if let previous, !matches(candidateBPM: candidate.bpm, candidateKey: candidate.camelot, reference: previous) { continue }
            queue.append(id)
            previous = candidate
        }
        return queue
    }
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
