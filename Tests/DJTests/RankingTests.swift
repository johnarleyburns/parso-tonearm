import XCTest

@testable import TonearmDJ

/// Hybrid scorer (§28.1, App. G.5): weighted composition, gaussian bpmFit,
/// graded Camelot reuse, energy/phrase fit, RankBreakdown decomposition, and
/// deterministic tie handling (NFR-DET-3).
final class RankingTests: XCTestCase {

    private func key(_ code: String) -> CamelotKey {
        guard let parsed = CamelotKey(code: code) else {
            fatalError("bad test key \(code)")
        }
        return parsed
    }

    // MARK: - Weighted composition

    func testFusedScoreIsWeightedComposition() {
        // All components at 1.0 → fused is the sum of the weights.
        let candidate = RankCandidate(semantic: 1.0, bpm: 124, camelot: key("8A"),
                                      energy: 7, phraseLength: 16)
        let target = RankTarget(bpm: 124, camelot: key("8A"), energy: 7,
                                phraseLength: 16, bpmTolerance: 3)
        let breakdown = HybridRanker.fusedScore(candidate, target: target,
                                                weights: .default)
        XCTAssertEqual(breakdown.semantic, 1.0, accuracy: 1e-9)
        XCTAssertEqual(breakdown.bpm, 1.0, accuracy: 1e-9)
        XCTAssertEqual(breakdown.key, 1.0, accuracy: 1e-9)
        XCTAssertEqual(breakdown.energy, 1.0, accuracy: 1e-9)
        XCTAssertEqual(breakdown.phrase, 1.0, accuracy: 1e-9)
        XCTAssertEqual(breakdown.fused, 1.0, accuracy: 1e-9)
    }

    func testFusedScoreWeightsApplyPerComponent() {
        // Semantic 0.5 only: fused = 0.40·0.5 + 0.20·0.5 + 0.20·0.5 + 0.10·0.5 + 0.10·0.5.
        let candidate = RankCandidate(semantic: 0.5)
        let target = RankTarget()
        let breakdown = HybridRanker.fusedScore(candidate, target: target,
                                                weights: .default)
        XCTAssertEqual(breakdown.fused, 0.5, accuracy: 1e-9)
    }

    func testCustomWeightsChangeComposition() {
        let weights = RankWeights(semantic: 1.0, bpm: 0, key: 0, energy: 0, phrase: 0)
        let candidate = RankCandidate(semantic: 0.7)
        let breakdown = HybridRanker.fusedScore(candidate, target: RankTarget(),
                                                weights: weights)
        XCTAssertEqual(breakdown.fused, 0.7, accuracy: 1e-9)
    }

    // MARK: - bpmFit (gaussian)

    func testBpmFitGaussianDecaysOverTolerance() {
        XCTAssertEqual(HybridRanker.bpmFit(candidate: 124, target: 124, tolerance: 3), 1.0,
                       accuracy: 1e-9)
        // gaussian(3, sigma 3) = exp(-0.5).
        XCTAssertEqual(HybridRanker.bpmFit(candidate: 127, target: 124, tolerance: 3),
                       exp(-0.5), accuracy: 1e-9)
        // Symmetric.
        XCTAssertEqual(HybridRanker.bpmFit(candidate: 121, target: 124, tolerance: 3),
                       exp(-0.5), accuracy: 1e-9)
        // A wide tolerance barely penalizes a small deviation.
        let wide = HybridRanker.bpmFit(candidate: 126, target: 124, tolerance: 10)
        XCTAssertGreaterThan(wide, 0.95)
    }

    func testBpmFitNeutralWhenEitherSideMissing() {
        XCTAssertEqual(HybridRanker.bpmFit(candidate: nil, target: 124, tolerance: 3),
                       HybridRanker.neutral)
        XCTAssertEqual(HybridRanker.bpmFit(candidate: 124, target: nil, tolerance: 3),
                       HybridRanker.neutral)
    }

    // MARK: - keyFit (graded Camelot, App. B)

    func testKeyFitReusesCamelotCompatibilityGrades() {
        // `Camelot.compatibility` returns Float, so grades land with Float
        // precision; compare within 1e-5.
        let accuracy = 1e-5
        XCTAssertEqual(HybridRanker.keyFit(candidate: key("8A"), target: key("8A")), 1.0,
                       accuracy: accuracy)
        XCTAssertEqual(HybridRanker.keyFit(candidate: key("8A"), target: key("8B")), 0.9,
                       accuracy: accuracy)
        XCTAssertEqual(HybridRanker.keyFit(candidate: key("8A"), target: key("7A")), 0.7,
                       accuracy: accuracy)
        XCTAssertEqual(HybridRanker.keyFit(candidate: key("8A"), target: key("9A")), 0.7,
                       accuracy: accuracy)
        // Energy-boost (+7 semitones / half wheel) → 0.5.
        XCTAssertEqual(HybridRanker.keyFit(candidate: key("8A"), target: key("2A")), 0.5,
                       accuracy: accuracy)
        XCTAssertEqual(HybridRanker.keyFit(candidate: key("8A"), target: key("5A")), 0.0,
                       accuracy: accuracy)
    }

    func testKeyFitNeutralWhenEitherSideMissing() {
        XCTAssertEqual(HybridRanker.keyFit(candidate: nil, target: key("8A")),
                       HybridRanker.neutral)
        XCTAssertEqual(HybridRanker.keyFit(candidate: key("8A"), target: nil),
                       HybridRanker.neutral)
    }

    // MARK: - energyFit / phraseFit

    func testEnergyFitClosesGapOnTenPointScale() {
        XCTAssertEqual(HybridRanker.energyFit(candidate: 7, target: 7), 1.0, accuracy: 1e-9)
        XCTAssertEqual(HybridRanker.energyFit(candidate: 9, target: 7), 0.8, accuracy: 1e-9)
        XCTAssertEqual(HybridRanker.energyFit(candidate: 3, target: 7), 0.6, accuracy: 1e-9)
        XCTAssertEqual(HybridRanker.energyFit(candidate: 10, target: 0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(HybridRanker.energyFit(candidate: nil, target: 7),
                       HybridRanker.neutral)
    }

    func testPhraseFitBarMultipleMatch() {
        XCTAssertEqual(HybridRanker.phraseFit(candidate: 16, target: 16), 1.0, accuracy: 1e-9)
        XCTAssertEqual(HybridRanker.phraseFit(candidate: 32, target: 16), 1.0, accuracy: 1e-9)
        XCTAssertEqual(HybridRanker.phraseFit(candidate: 8, target: 16), 1.0, accuracy: 1e-9)
        // Half a bar off the nearest multiple → 0.5.
        XCTAssertEqual(HybridRanker.phraseFit(candidate: 24, target: 16), 0.5, accuracy: 1e-9)
        XCTAssertEqual(HybridRanker.phraseFit(candidate: nil, target: 16),
                       HybridRanker.neutral)
    }

    // MARK: - RankBreakdown decomposition

    func testBreakdownCarriesPerComponentValues() {
        let candidate = RankCandidate(semantic: 0.8, bpm: 120, camelot: key("6A"),
                                      energy: 4, phraseLength: 16)
        let target = RankTarget(bpm: 126, camelot: key("6B"), energy: 8,
                                phraseLength: 32, bpmTolerance: 3)
        let breakdown = HybridRanker.fusedScore(candidate, target: target,
                                                weights: .default)
        XCTAssertEqual(breakdown.semantic, 0.8, accuracy: 1e-9)
        XCTAssertEqual(breakdown.bpm, exp(-0.5 * pow(6.0 / 3.0, 2)), accuracy: 1e-9)
        XCTAssertEqual(breakdown.key, 0.9, accuracy: 1e-5)   // 6A relative 6B (Float)
        XCTAssertEqual(breakdown.energy, 0.6, accuracy: 1e-9)  // 1 − 4/10
        XCTAssertEqual(breakdown.phrase, 1.0, accuracy: 1e-9)  // 16 ↔ 32 bar-multiple
        XCTAssertEqual(breakdown.fused, 0.40 * 0.8 + 0.20 * breakdown.bpm
                       + 0.20 * 0.9 + 0.10 * 0.6 + 0.10 * 1.0, accuracy: 1e-5)
    }

    // MARK: - Tie handling (deterministic order, NFR-DET-3)

    func testOrderingBreaksTiesBySemanticThenTrackID() {
        let b1 = RankBreakdown(semantic: 0.5, bpm: 0.5, key: 0.5, energy: 0.5,
                               phrase: 0.5, fused: 0.5)
        let b2 = RankBreakdown(semantic: 0.6, bpm: 0.5, key: 0.5, energy: 0.5,
                               phrase: 0.5, fused: 0.5)
        let b3 = RankBreakdown(semantic: 0.6, bpm: 0.5, key: 0.5, energy: 0.5,
                               phrase: 0.5, fused: 0.5)
        let input = [
            RankedMatch(rowID: 30, semantic: 0.6, breakdown: b2),
            RankedMatch(rowID: 10, semantic: 0.6, breakdown: b3),
            RankedMatch(rowID: 20, semantic: 0.5, breakdown: b1),
            RankedMatch(rowID: 40, semantic: 0.9, breakdown: b1),
        ]
        let ordered = HybridRankerOrdering.order(input)
        XCTAssertEqual(ordered.map(\.rowID), [40, 10, 30, 20])
    }

    func testOrderingIsStableAndDeterministic() {
        var seed: [RankedMatch] = []
        for i in 0..<50 {
            let semantic = Double((i * 7) % 3) / 3
            let fused = Double((i * 5) % 7) / 7
            let breakdown = RankBreakdown(semantic: 0.5, bpm: 0.5, key: 0.5,
                                          energy: 0.5, phrase: 0.5, fused: fused)
            seed.append(RankedMatch(rowID: Int64(i), semantic: semantic,
                                    breakdown: breakdown))
        }
        let shuffled = seed.shuffled()
        XCTAssertEqual(HybridRankerOrdering.order(seed), HybridRankerOrdering.order(shuffled))
    }
}
