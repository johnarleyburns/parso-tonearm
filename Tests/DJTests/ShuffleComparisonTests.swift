import XCTest

@testable import TonearmDJ

/// AT-PLIST-3 (§28A.7, plan §3.5): the shuffle-comparison harness. For each
/// synthetic corpus the mean `transitionCost` of the generated sequence must be
/// at least 40% lower than the mean over seeded random permutations of the
/// *same track set*. This is the test that proves the sequencer optimises the
/// order — a generator that merely filtered the pool would score identically to
/// shuffle. Fully deterministic: permutations come from SplitMix64, never
/// ambient entropy (NFR-DET-3).
final class ShuffleComparisonTests: XCTestCase {

    // MARK: - Helpers

    /// Deterministic synthetic corpus — the same shape as `SequencerTests`'
    /// maker, so the corpora this gate runs over match the other AT-PLIST tests.
    private func makeCandidates(count: Int, seed: UInt64, durationBase: Double = 210,
                                artistCount: Int = 40, albumCount: Int = 25,
                                dims: Int = 8) -> [TrackFeatures] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { i in
            let id = Int64(i + 1)
            let duration = durationBase + 90 * (Double(rng.next() % 100_000) / 100_000 - 0.5)
            let bpm = 110 + 30 * (Double(rng.next() % 100_000) / 100_000)
            let number = Int(rng.next() % 12) + 1
            let letter = (rng.next() % 2 == 0) ? "A" : "B"
            let energy = Double(rng.next() % 100_000) / 100_000
            let embedding = (0..<dims).map { _ -> Float in
                Float(Double(rng.next() % 200_000) / 100_000 - 1)
            }
            return TrackFeatures(trackID: id,
                                 durationSec: duration,
                                 bpm: bpm,
                                 camelot: CamelotKey(code: "\(number)\(letter)"),
                                 energy: energy,
                                 embedding: embedding,
                                 artistIDs: [Int64(i % artistCount) + 1],
                                 albumID: Int64(i % albumCount) + 1)
        }
    }

    /// Mean transition cost over the n − 1 adjacent transitions of a sequence —
    /// the same metric applied to the generated ordering and to every shuffle,
    /// so only the order differs.
    private func meanTransitionCost(_ tracks: [TrackFeatures],
                                    _ constraints: SequencingConstraints) -> Double {
        guard tracks.count > 1 else { return 0 }
        let total = (1..<tracks.count).reduce(0.0) { sum, i in
            sum + PlaylistSequencer.transitionCost(tracks[i - 1], tracks[i], constraints)
        }
        return total / Double(tracks.count - 1)
    }

    /// The shuffle baseline: mean transition cost over `permutations` seeded
    /// random permutations (Fisher–Yates via SplitMix64) of the exact track set
    /// the sequencer chose.
    private func shuffleMeanTransitionCost(_ tracks: [TrackFeatures],
                                           _ constraints: SequencingConstraints,
                                           permutations: Int,
                                           seed: UInt64) -> Double {
        var rng = SplitMix64(seed: seed)
        var total = 0.0
        for _ in 0..<permutations {
            var shuffled = tracks
            for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
                let j = Int(rng.next() % UInt64(i + 1))
                shuffled.swapAt(i, j)
            }
            total += meanTransitionCost(shuffled, constraints)
        }
        return total / Double(permutations)
    }

    // MARK: - AT-PLIST-3

    func testGeneratedSequenceAtLeastFortyPercentSmootherThanShuffle() {
        let corpusSeeds: [UInt64] = [12, 21, 29]
        let arcs: [EnergyArc] = [
            .steady(level: 0.5),
            .build,
            .peakAndRelease(peakAt: 0.7),
            .windDown,
            .wave(cycles: 1.0),
        ]
        let constraints = SequencingConstraints()
        var comparisons = 0
        for corpusSeed in corpusSeeds {
            let library = makeCandidates(count: 300, seed: corpusSeed)
            let byID = Dictionary(uniqueKeysWithValues: library.map { ($0.trackID, $0) })
            for arc in arcs {
                let slots = PlaylistSequencer.sequence(
                    candidates: library,
                    brief: PlaylistBrief(targetSeconds: 3600, arc: arc),
                    seed: corpusSeed &* 7 &+ 1)
                XCTAssertGreaterThan(slots.count, 1,
                                     "corpus \(corpusSeed) arc \(arc.kindCode) has no transitions")
                let sequenced = slots.map { byID[$0.trackID]! }
                let generated = meanTransitionCost(sequenced, constraints)
                let shuffled = shuffleMeanTransitionCost(sequenced, constraints,
                                                         permutations: 200,
                                                         seed: corpusSeed &* 0x1234_5678
                                                             &+ UInt64(comparisons))
                let ratio = generated / shuffled
                XCTAssertLessThanOrEqual(
                    generated, 0.60 * shuffled,
                    "corpus \(corpusSeed) arc \(arc.kindCode): generated "
                        + String(format: "%.3f", generated)
                        + " vs shuffle " + String(format: "%.3f", shuffled)
                        + " — ratio " + String(format: "%.2f", ratio))
                comparisons += 1
            }
        }
        XCTAssertGreaterThanOrEqual(comparisons, 5, "needs at least the five preset arcs")
    }
}
