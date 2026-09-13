import Foundation

// MARK: - Beam search steps 3-4 (§28A.3)

extension PlaylistSequencer {

    // MARK: Step 3 — seed the beam

    static func seedEntries(candidates: [TrackFeatures], count: Int, brief: PlaylistBrief,
                            weights: SequenceWeights, target: Double?,
                            median: Double, seed: UInt64) -> [BeamEntry] {
        let lockedTracks = Set(brief.locks.values)
        let pool: [TrackFeatures]
        if let locked = brief.locks[0] {
            pool = candidates.filter { $0.trackID == locked }
        } else {
            pool = candidates.filter { !lockedTracks.contains($0.trackID) }
        }
        let seeded = pool.sorted { a, b in
            let sa = headScore(a, slot: 0, count: count, brief: brief, weights: weights,
                               target: target, median: median)
            let sb = headScore(b, slot: 0, count: count, brief: brief, weights: weights,
                               target: target, median: median)
            if sa != sb { return sa < sb }
            return tieBreak(a.trackID, seed: seed) < tieBreak(b.trackID, seed: seed)
        }
        return seeded.prefix(beamWidth).map { track in
            BeamEntry(tracks: [track],
                      score: headScore(track, slot: 0, count: count, brief: brief,
                                       weights: weights, target: target, median: median),
                      totalDuration: track.durationSec)
        }
    }

    /// The head-slot score: arc + semantic alone (§28A.3 step 3), plus the
    /// duration term (it only engages for n = 1, where the head is the whole
    /// playlist).
    private static func headScore(_ track: TrackFeatures, slot: Int, count: Int,
                                  brief: PlaylistBrief, weights: SequenceWeights,
                                  target: Double?, median: Double) -> Double {
        arcTerm(track, slot: slot, count: count, brief: brief, weights: weights)
            + semanticTerm(track, brief: brief, weights: weights)
            + durationTerm(partialTotal: 0, candidateDuration: track.durationSec,
                           slot: slot, count: count, target: target, median: median,
                           weights: weights)
    }

    // MARK: Step 4 — extend the beam

    static func extend(beam: [BeamEntry], slot: Int, count: Int,
                       candidates: [TrackFeatures], brief: PlaylistBrief,
                       weights: SequenceWeights, arcPool: [TrackFeatures],
                       byID: [Int64: TrackFeatures], target: Double?,
                       median: Double, seed: UInt64) -> [BeamEntry] {
        let lockedTracks = Set(brief.locks.values)
        let locked = brief.locks[slot]
        var entries: [BeamEntry] = []
        var keys: [(score: Double, lastTie: UInt64, secondLastTie: UInt64, index: Int)] = []

        for entry in beam {
            let used = Set(entry.tracks.map(\.trackID))
            let tail = entry.tracks[entry.tracks.count - 1]

            // The M best next candidates (§28A.3 step 4), from the arc pool or
            // (for a locked slot) the locked track alone. Tiny tuple keys keep
            // the per-partial sort cheap even in unoptimized test builds.
            let pool = locked.map { lockedTrack in
                candidates.filter { candidate in
                    candidate.trackID == lockedTrack
                        && !used.contains(candidate.trackID)
                        && spacingOK(candidate, at: slot, in: entry.tracks,
                                     constraints: brief.constraints)
                }
            } ?? arcPool.filter { candidate in
                !used.contains(candidate.trackID)
                    && !lockedTracks.contains(candidate.trackID)
                    && spacingOK(candidate, at: slot, in: entry.tracks,
                                 constraints: brief.constraints)
            }

            var best: [(score: Double, tie: UInt64, trackID: Int64)] = []
            best.reserveCapacity(pool.count)
            for candidate in pool {
                let preScore = PlaylistSequencer.transitionCost(tail, candidate, brief.constraints)
                    + arcError(candidate, slot: slot, count: count, arc: brief.arc)
                best.append((preScore, tieBreak(candidate.trackID, seed: seed), candidate.trackID))
            }
            best.sort { l, r in
                if l.0 != r.0 { return l.0 < r.0 }
                return l.1 < r.1
            }

            for scored in best.prefix(branchingFactor) {
                guard let candidate = byID[scored.2] else { continue }
                let arc = arcTerm(candidate, slot: slot, count: count, brief: brief, weights: weights)
                let semantic = semanticTerm(candidate, brief: brief, weights: weights)
                let transition = weights.transition
                    * PlaylistSequencer.transitionCost(tail, candidate, brief.constraints)
                let duration = durationTerm(partialTotal: entry.totalDuration,
                                            candidateDuration: candidate.durationSec,
                                            slot: slot, count: count, target: target,
                                            median: median, weights: weights)
                let score = entry.score + arc + semantic + transition + duration
                var tracks = entry.tracks
                tracks.append(candidate)
                entries.append(BeamEntry(tracks: tracks, score: score,
                                         totalDuration: entry.totalDuration + candidate.durationSec))
                keys.append((score, tieBreak(candidate.trackID, seed: seed),
                             tieBreak(tail.trackID, seed: seed), entries.count - 1))
            }
        }

        // Keep the best K by score (ties by the seeded PRNG), then the
        // last-two-tracks diversity guard.
        keys.sort { l, r in
            if l.score != r.score { return l.score < r.score }
            if l.lastTie != r.lastTie { return l.lastTie < r.lastTie }
            return l.secondLastTie < r.secondLastTie
        }

        var seenTails: Set<[Int64]> = []
        var result: [BeamEntry] = []
        for key in keys {
            let tracks = entries[key.index].tracks
            let pair = [tracks[tracks.count - 2].trackID, tracks[tracks.count - 1].trackID]
            guard seenTails.insert(pair).inserted else { continue }
            result.append(entries[key.index])
            if result.count == beamWidth { break }
        }
        return result
    }
}
