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

extension SplitMix64: RandomNumberGenerator {
    /// SplitMix64's `next()` already yields full 64-bit words, so the type is
    /// a drop-in `RandomNumberGenerator` — the standard `random(in:using:)`
    /// family becomes deterministic too (NFR-DET-3).
}

// MARK: - Beam search (§28A.3)
//
// This file holds the entry point (`sequence(candidates:brief:seed:)`), the
// domain types above, and the count/duration/tie-break/output helpers. The
// beam-seed/extend steps live in `PlaylistSequencer+BeamSearch.swift`, the
// duration close-out in `PlaylistSequencer+CloseOut.swift`, and the scoring
// terms + spacing constraints in `PlaylistSequencer+Scoring.swift`. Several
// helpers below (`tieBreak`, the `BeamEntry` type) are used from those other
// files too, so they are kept at the implicit internal access level rather
// than `private`.

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
    static func tieBreak(_ trackID: Int64, seed: UInt64) -> UInt64 {
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

    struct BeamEntry {
        var tracks: [TrackFeatures]
        var score: Double
        var totalDuration: Double
    }
}
