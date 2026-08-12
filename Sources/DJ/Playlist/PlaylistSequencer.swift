import Foundation

// MARK: - Domain types

/// The pure sequencer's brief (§28A.1, plan §3.2): the target length, the
/// energy arc, the constraints, the locked slots, and the semantic scores the
/// generator resolved from its embedding query. Pure and Sendable — the row
/// record (`AutoPlaylistBrief`) and the generator actor land in commit 3.3.
public struct PlaylistBrief: Sendable, Equatable {
    /// Target duration T in seconds; nil when the brief targets a track count.
    public var targetSeconds: Double?
    /// Target track count N; takes precedence when set (§28A.3 step 2).
    public var targetTrackCount: Int?
    public var arc: EnergyArc
    public var constraints: SequencingConstraints
    /// slot → trackID for pinned slots (FR-PLIST-6 lock).
    public var locks: [Int: Int64]
    /// Semantic score per candidate from the brief's embedding query; a missing
    /// entry is the neutral 0.5 (§28A.1's `semanticScore(sᵢ, q)`).
    public var semanticScores: [Int64: Double]

    public init(targetSeconds: Double? = nil,
                targetTrackCount: Int? = nil,
                arc: EnergyArc,
                constraints: SequencingConstraints = SequencingConstraints(),
                locks: [Int: Int64] = [:],
                semanticScores: [Int64: Double] = [:]) {
        self.targetSeconds = targetSeconds
        self.targetTrackCount = targetTrackCount
        self.arc = arc
        self.constraints = constraints
        self.locks = locks
        self.semanticScores = semanticScores
    }
}

/// One slot of a generated sequence plus the per-item scoring the
/// `auto_playlist_item` row stores (§14.3). `targetEnergy`/`actualEnergy` are
/// the [0,1] arc value and the track's empirical-CDF rank; `transitionCostIn`
/// is the cost from the previous slot (0 for the first).
public struct SequencedSlot: Codable, Sendable, Equatable {
    public var position: Int
    public var trackID: Int64
    public var targetEnergy: Double
    public var actualEnergy: Double?
    public var transitionCostIn: Double
    public var semanticScore: Double

    public init(position: Int,
                trackID: Int64,
                targetEnergy: Double,
                actualEnergy: Double?,
                transitionCostIn: Double,
                semanticScore: Double) {
        self.position = position
        self.trackID = trackID
        self.targetEnergy = targetEnergy
        self.actualEnergy = actualEnergy
        self.transitionCostIn = transitionCostIn
        self.semanticScore = semanticScore
    }
}

/// Deterministic 64-bit SplitMix64 PRNG (plan §2.6). Same seed, same bytes —
/// never ambient entropy. It is the sole source of tie-breaks in the beam and
/// the close-out, so two devices with the same library + brief + seed produce
/// the same playlist (NFR-DET-1, AT-PLIST-6).
public struct SplitMix64: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Beam search (§28A.3)

extension PlaylistSequencer {

    /// Beam width K (§28A.3 step 3).
    public static let beamWidth = 24
    /// Branching factor M — next candidates considered per partial (§28A.3 step 4).
    public static let branchingFactor = 32
    /// The generator's semantic-pool cap (plan §2.7), reused as the sequencer's
    /// per-slot arc pool: the nearest `generatorPoolCap` candidates by energy at
    /// a slot are the ones the pre-rank and close-out draw from. At real library
    /// sizes (≤ 600 after the generator's own cap) the pool is the whole
    /// candidate set; the bound only bites at benchmark scale.
    public static let generatorPoolCap = 600
    /// ε — how much the close-out swap may raise J (plan §3.2, §28A.3 step 5).
    public static let closeOutSlack = 0.01
    /// n is at most ~40 (§28A.1).
    public static let maxTrackCount = 40
    /// FR-PLIST-2's duration tolerance for the close-out loop.
    public static let closeOutTolerance = 0.05

    /// §28A.2's energy distance from what the arc asks at `position` of `count`
    /// (normalized `t = position / (count − 1)`, single-slot anchored at t = 0).
    public static func arcError(energy: Double, position: Int, count: Int, arc: EnergyArc) -> Double {
        let t = count > 1 ? Double(position) / Double(count - 1) : 0
        return abs(energy - arc.value(at: t))
    }

    /// The §28A.3 beam search. Pure, synchronous, deterministic (NFR-DET-3):
    /// same candidates + brief + seed ⇒ same `[SequencedSlot]`, byte for byte.
    ///
    /// Step 3 seeds the beam with the K best head tracks by arc + semantic;
    /// step 4 extends slot by slot over the M best next candidates (from a
    /// per-slot nearest-by-energy arc pool, ranked by transition cost +
    /// arcError) scored by the running J with a duration-aware term that engages
    /// once the running total is within one track of T, keeping the best K under
    /// the last-two-tracks diversity guard and honouring locks (a locked slot
    /// admits exactly one candidate) and spacing (hard reject); step 5 closes
    /// the duration gap with the single-track swap that best closes it without
    /// raising J by more than ε, iterating to a fixpoint (FR-PLIST-2).
    public static func sequence(candidates: [TrackFeatures], brief: PlaylistBrief,
                                seed: UInt64) -> [SequencedSlot] {
        guard !candidates.isEmpty else { return [] }
        let count = resolvedCount(candidates: candidates, brief: brief)
        guard count > 0 else { return [] }
        let weights = SequenceWeights.default
        let median = medianDuration(candidates)
        let target = (brief.targetSeconds ?? 0) > 0 ? brief.targetSeconds : nil

        // Static per-slot arc value over the fixed length (step 2's estimate of n).
        let arcTarget = (0..<count).map { slot -> Double in
            let t = count > 1 ? Double(slot) / Double(count - 1) : 0
            return brief.arc.value(at: t)
        }

        // Candidates once sorted by (energy, tie): every slot's arc pool is a
        // nearest-by-energy window of that single ordering, so the pre-rank and
        // close-out stay bounded at benchmark scale (one sort, not one per slot).
        let sortedByEnergy = candidates.sorted { a, b in
            let ea = a.energy ?? neutral
            let eb = b.energy ?? neutral
            if ea != eb { return ea < eb }
            return tieBreak(a.trackID, seed: seed) < tieBreak(b.trackID, seed: seed)
        }
        let energies = sortedByEnergy.map { $0.energy ?? neutral }
        let arcPoolBySlot: [[TrackFeatures]] = (0..<count).map { slot in
            nearestEnergies(sortedByEnergy, energies: energies,
                            target: arcTarget[slot], limit: generatorPoolCap, seed: seed)
        }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.trackID, $0) })

        var beam = seedEntries(candidates: candidates, count: count, brief: brief,
                               weights: weights, target: target, median: median, seed: seed)
        guard !beam.isEmpty else { return [] }

        var lastBeam = beam
        for slot in 1..<count {
            lastBeam = beam
            beam = extend(beam: beam, slot: slot, count: count, candidates: candidates,
                          brief: brief, weights: weights, arcPool: arcPoolBySlot[slot],
                          byID: byID, target: target, median: median, seed: seed)
            if beam.isEmpty {
                beam = lastBeam
                break
            }
        }

        guard let best = beam.min(by: { $0.score < $1.score }) else { return [] }
        let finalTracks = closeOut(tracks: best.tracks, count: count, brief: brief,
                                   arcPools: arcPoolBySlot, seed: seed)
        return buildSlots(finalTracks, brief: brief, weights: weights, arcTarget: arcTarget)
    }

    /// The nearest `limit` candidates by |energy − target| over the
    /// energy-sorted pool. Two-pointer walk around the insertion point — exact,
    /// deterministic (ties by the seed tie-break), O(limit) after one binary
    /// search, so a 30k-pool benchmark never sorts per slot.
    private static func nearestEnergies(_ sorted: [TrackFeatures], energies: [Double],
                                        target: Double, limit: Int, seed: UInt64) -> [TrackFeatures] {
        guard limit > 0 else { return [] }
        var lower = 0
        var upper = sorted.count - 1
        var pivot = 0
        while lower <= upper {
            let mid = (lower + upper) / 2
            if energies[mid] < target {
                lower = mid + 1
            } else {
                upper = mid - 1
                pivot = mid
            }
        }
        var left = pivot - 1
        var right = pivot
        var result: [TrackFeatures] = []
        result.reserveCapacity(min(limit, sorted.count))
        while result.count < limit, left >= 0 || right < sorted.count {
            if left < 0 {
                result.append(sorted[right])
                right += 1
            } else if right >= sorted.count {
                result.append(sorted[left])
                left -= 1
            } else {
                let dLeft = abs(energies[left] - target)
                let dRight = abs(energies[right] - target)
                let tLeft = tieBreak(sorted[left].trackID, seed: seed)
                let tRight = tieBreak(sorted[right].trackID, seed: seed)
                if dLeft < dRight || (dLeft == dRight && tLeft < tRight) {
                    result.append(sorted[left])
                    left -= 1
                } else {
                    result.append(sorted[right])
                    right += 1
                }
            }
        }
        return result
    }

    // MARK: Step 3 — seed the beam

    private static func seedEntries(candidates: [TrackFeatures], count: Int, brief: PlaylistBrief,
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

    private static func extend(beam: [BeamEntry], slot: Int, count: Int,
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

    // MARK: Step 5 — duration close-out

    /// If |duration − T| > 5%: repeatedly swap the single track whose
    /// replacement best closes the gap without raising J by more than ε
    /// (§28A.3 step 5, iterated to a fixpoint so FR-PLIST-2's ±5% is met).
    /// Swaps draw from each slot's arc-faithful pool so the ε gate is what
    /// decides, at a bounded cost even for a 30k-pool benchmark.
    private static func closeOut(tracks: [TrackFeatures], count: Int, brief: PlaylistBrief,
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

    // MARK: Scoring terms

    /// arcError over a candidate: missing energy contributes the neutral 0.5.
    private static func arcError(_ track: TrackFeatures, slot: Int, count: Int,
                                 arc: EnergyArc) -> Double {
        guard let energy = track.energy else { return neutral }
        return arcError(energy: energy, position: slot, count: count, arc: arc)
    }

    /// The arc term of J. A missing energy contributes the neutral 0.5 (the
    /// missing-attribute convention): an unanalysed track cannot win on arc
    /// adherence, but is not catastrophically penalised.
    private static func arcTerm(_ track: TrackFeatures, slot: Int, count: Int,
                                brief: PlaylistBrief, weights: SequenceWeights) -> Double {
        guard let energy = track.energy else { return weights.arc * neutral }
        return weights.arc * arcError(energy: energy, position: slot, count: count, arc: brief.arc)
    }

    /// The `w_s · (1 − semanticScore(sᵢ, q))` term of J; missing score → neutral.
    private static func semanticTerm(_ track: TrackFeatures, brief: PlaylistBrief,
                                     weights: SequenceWeights) -> Double {
        let score = brief.semanticScores[track.trackID] ?? neutral
        return weights.semantic * (1 - score)
    }

    /// The duration-aware term of step 4: zero until the running total is within
    /// one track (the median duration) of T, then `w_d · |projected − T| / T`
    /// where `projected` fills the remaining slots at the median — so pressure
    /// only appears as the sequence approaches its target, and equals the J
    /// duration term exactly at the final slot.
    private static func durationTerm(partialTotal: Double, candidateDuration: Double,
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
    private static func spacingOK(_ track: TrackFeatures, at slot: Int,
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
    private static func spacingAfterSwap(_ tracks: [TrackFeatures], replacing slot: Int,
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

    // MARK: Count and duration helpers

    /// Estimate n (§28A.3 step 2): the brief's track count, else `round(T /
    /// medianDuration(C))`, capped at maxTrackCount, never exceeding the pool,
    /// and never shorter than the highest locked slot + 1.
    private static func resolvedCount(candidates: [TrackFeatures], brief: PlaylistBrief) -> Int {
        var n: Int
        if let requested = brief.targetTrackCount, requested > 0 {
            n = min(requested, candidates.count, maxTrackCount)
        } else {
            let median = medianDuration(candidates)
            if let target = brief.targetSeconds, target > 0, median > 0 {
                n = min(max(1, Int((target / median).rounded())), candidates.count, maxTrackCount)
            } else {
                n = min(candidates.count, maxTrackCount)
            }
        }
        if let highestLock = brief.locks.keys.max() {
            n = max(n, highestLock + 1)
        }
        return min(n, candidates.count)
    }

    private static func medianDuration(_ candidates: [TrackFeatures]) -> Double {
        guard !candidates.isEmpty else { return 0 }
        let sorted = candidates.map(\.durationSec).sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    // MARK: Deterministic tie-breaks

    /// A per-track tie-break value derived from the brief's seed through the
    /// seeded SplitMix64 PRNG. Order-independent (a function of trackID, not of
    /// array position), so the sequence is byte-identical regardless of how the
    /// candidate set was ordered (NFR-DET-3).
    private static func tieBreak(_ trackID: Int64, seed: UInt64) -> UInt64 {
        var rng = SplitMix64(seed: seed &+ UInt64(bitPattern: trackID) &* 0x9E37_79B9_7F4A_7C15)
        return rng.next()
    }

    // MARK: Output

    private static func buildSlots(_ tracks: [TrackFeatures], brief: PlaylistBrief,
                                   weights: SequenceWeights, arcTarget: [Double]) -> [SequencedSlot] {
        let constraints = brief.constraints
        return tracks.enumerated().map { slot, track in
            let costIn: Double
            if slot == 0 {
                costIn = 0
            } else {
                costIn = PlaylistSequencer.transitionCost(tracks[slot - 1], track, constraints)
            }
            return SequencedSlot(position: slot,
                                 trackID: track.trackID,
                                 targetEnergy: arcTarget[slot],
                                 actualEnergy: track.energy,
                                 transitionCostIn: costIn,
                                 semanticScore: brief.semanticScores[track.trackID] ?? neutral)
        }
    }

    // MARK: Internal state

    private struct BeamEntry {
        var tracks: [TrackFeatures]
        var score: Double
        var totalDuration: Double
    }
}
