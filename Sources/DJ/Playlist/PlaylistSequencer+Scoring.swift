import Foundation

// MARK: - Scoring terms and spacing (hard constraints)

extension PlaylistSequencer {

    /// arcError over a candidate: missing energy contributes the neutral 0.5.
    static func arcError(_ track: TrackFeatures, slot: Int, count: Int,
                         arc: EnergyArc) -> Double {
        guard let energy = track.energy else { return neutral }
        return arcError(energy: energy, position: slot, count: count, arc: arc)
    }

    /// The arc term of J. A missing energy contributes the neutral 0.5 (the
    /// missing-attribute convention): an unanalysed track cannot win on arc
    /// adherence, but is not catastrophically penalised.
    static func arcTerm(_ track: TrackFeatures, slot: Int, count: Int,
                        brief: PlaylistBrief, weights: SequenceWeights) -> Double {
        guard let energy = track.energy else { return weights.arc * neutral }
        return weights.arc * arcError(energy: energy, position: slot, count: count, arc: brief.arc)
    }

    /// The `w_s · (1 − semanticScore(sᵢ, q))` term of J; missing score → neutral.
    static func semanticTerm(_ track: TrackFeatures, brief: PlaylistBrief,
                             weights: SequenceWeights) -> Double {
        let score = brief.semanticScores[track.trackID] ?? neutral
        return weights.semantic * (1 - score)
    }

    /// The duration-aware term of step 4: zero until the running total is within
    /// one track (the median duration) of T, then `w_d · |projected − T| / T`
    /// where `projected` fills the remaining slots at the median — so pressure
    /// only appears as the sequence approaches its target, and equals the J
    /// duration term exactly at the final slot.
    static func durationTerm(partialTotal: Double, candidateDuration: Double,
                             slot: Int, count: Int, target: Double?, median: Double,
                             weights: SequenceWeights) -> Double {
        guard let target, target > 0, median > 0 else { return 0 }
        let running = partialTotal + candidateDuration
        guard abs(running - target) <= median else { return 0 }
        let remaining = count - (slot + 1)
        let projected = running + Double(remaining) * median
        return weights.duration * (abs(projected - target) / target)
    }

    // MARK: Spacing (hard constraints)

    /// `minArtistGap` / `minAlbumGap` slots between same-artist / same-album
    /// tracks. Checked over the window before `slot`; mutual (sharing an artist
    /// with any earlier track in the window is a breach in either direction).
    static func spacingOK(_ track: TrackFeatures, at slot: Int,
                          in sequence: [TrackFeatures],
                          constraints: SequencingConstraints) -> Bool {
        if constraints.minArtistGap > 0, !track.artistIDs.isEmpty {
            let start = max(0, slot - constraints.minArtistGap)
            for i in start..<slot where !sequence[i].artistIDs.isEmpty {
                let previousArtists = sequence[i].artistIDs
                if track.artistIDs.contains(where: { previousArtists.contains($0) }) { return false }
            }
        }
        if constraints.minAlbumGap > 0, let album = track.albumID {
            let start = max(0, slot - constraints.minAlbumGap)
            for i in start..<slot where sequence[i].albumID == album { return false }
        }
        return true
    }

    /// Public validity check over a whole sequence — the generator's replace and
    /// reshuffle re-validate after a local change (§28A.4).
    public static func validateSpacing(_ tracks: [TrackFeatures],
                                       constraints: SequencingConstraints) -> Bool {
        for slot in 1..<tracks.count where !spacingOK(tracks[slot], at: slot, in: tracks,
                                                      constraints: constraints) {
            return false
        }
        return true
    }

    /// Validate spacing after swapping `replacement` into `slot`. Only the
    /// candidate and the tracks within one gap window after it can newly
    /// violate the constraints — everything before `slot` is untouched, and
    /// `spacingOK` at any `j > slot` looks back through a window that includes
    /// the changed slot. O(gap), no sequence copy.
    static func spacingAfterSwap(_ tracks: [TrackFeatures], replacing slot: Int,
                                 with replacement: TrackFeatures,
                                 constraints: SequencingConstraints) -> Bool {
        var trial = tracks
        trial[slot] = replacement
        if !spacingOK(trial[slot], at: slot, in: trial, constraints: constraints) { return false }
        let maxGap = max(constraints.minArtistGap, constraints.minAlbumGap)
        let limit = min(trial.count - 1, slot + maxGap)
        if slot + 1 <= limit {
            for j in (slot + 1)...limit
            where !spacingOK(trial[j], at: j, in: trial, constraints: constraints) {
                return false
            }
        }
        return true
    }
}
