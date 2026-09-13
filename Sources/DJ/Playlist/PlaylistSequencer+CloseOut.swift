import Foundation

// MARK: - Beam search step 5 — duration close-out (§28A.3)

extension PlaylistSequencer {

    /// If |duration − T| > 5%: repeatedly swap the single track whose
    /// replacement best closes the gap without raising J by more than ε
    /// (§28A.3 step 5, iterated to a fixpoint so FR-PLIST-2's ±5% is met).
    /// Swaps draw from each slot's arc-faithful pool so the ε gate is what
    /// decides, at a bounded cost even for a 30k-pool benchmark.
    static func closeOut(tracks: [TrackFeatures], count: Int, brief: PlaylistBrief,
                         arcPools: [[TrackFeatures]], seed: UInt64) -> [TrackFeatures] {
        guard let target = brief.targetSeconds, target > 0, count > 0 else { return tracks }
        let lockedTracks = Set(brief.locks.values)
        var result = tracks
        var total = tracks.reduce(0) { $0 + $1.durationSec }
        var iterations = 0

        while abs(total - target) / target > closeOutTolerance && iterations < 24 {
            iterations += 1
            let usedIDs = Set(result.map(\.trackID))
            var best: (slot: Int, track: TrackFeatures, reduction: Double,
                       jDelta: Double, tie: UInt64)?
            for slot in 0..<count where brief.locks[slot] == nil {
                let current = result[slot]
                for candidate in arcPools[slot] {
                    guard candidate.trackID != current.trackID,
                          !lockedTracks.contains(candidate.trackID),
                          !usedIDs.contains(candidate.trackID) else { continue }
                    let newTotal = total - current.durationSec + candidate.durationSec
                    let gapNow = abs(total - target)
                    let gapNew = abs(newTotal - target)
                    guard gapNew < gapNow else { continue }
                    // Only the window around the swap can newly violate spacing,
                    // so validate locally instead of copying and re-checking the
                    // whole sequence (§28A.3 step 5 keeps the swap local).
                    guard spacingAfterSwap(result, replacing: slot, with: candidate,
                                           constraints: brief.constraints) else { continue }
                    let jDelta = closeOutJDelta(replacing: slot, with: candidate, in: result,
                                                count: count, brief: brief)
                    guard jDelta <= closeOutSlack else { continue }
                    let candidateEntry = (slot, candidate, gapNow - gapNew, jDelta,
                                          tieBreak(candidate.trackID, seed: seed))
                    if let existing = best {
                        if candidateEntry.2 > existing.2
                            || (candidateEntry.2 == existing.2 && candidateEntry.3 < existing.3)
                            || (candidateEntry.2 == existing.2 && candidateEntry.3 == existing.3
                                && candidateEntry.4 < existing.4) {
                            best = candidateEntry
                        }
                    } else {
                        best = candidateEntry
                    }
                }
            }
            guard let chosen = best else { break }
            let replaced = result[chosen.0]
            result[chosen.0] = chosen.1
            total = total - replaced.durationSec + chosen.1.durationSec
            if abs(total - target) / target <= closeOutTolerance { break }
        }
        return result
    }

    /// The change in the musical part of J (arc + semantic + transition) from
    /// swapping `candidate` into `slot`. The duration term is deliberately
    /// excluded: closing the duration gap *is* the objective being optimised.
    private static func closeOutJDelta(replacing slot: Int, with candidate: TrackFeatures,
                                       in tracks: [TrackFeatures], count: Int,
                                       brief: PlaylistBrief) -> Double {
        let weights = SequenceWeights.default
        let current = tracks[slot]
        var delta = arcTerm(candidate, slot: slot, count: count, brief: brief, weights: weights)
            - arcTerm(current, slot: slot, count: count, brief: brief, weights: weights)
            + semanticTerm(candidate, brief: brief, weights: weights)
            - semanticTerm(current, brief: brief, weights: weights)
        if slot > 0 {
            let previous = tracks[slot - 1]
            delta += weights.transition
                * (PlaylistSequencer.transitionCost(previous, candidate, brief.constraints)
                   - PlaylistSequencer.transitionCost(previous, current, brief.constraints))
        }
        if slot < count - 1 {
            let next = tracks[slot + 1]
            delta += weights.transition
                * (PlaylistSequencer.transitionCost(candidate, next, brief.constraints)
                   - PlaylistSequencer.transitionCost(current, next, brief.constraints))
        }
        return delta
    }
}
