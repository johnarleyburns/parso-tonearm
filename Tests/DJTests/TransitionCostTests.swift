import XCTest

@testable import TonearmDJ

final class TransitionCostTests: XCTestCase {

    // MARK: - Helpers

    /// A candidate with sensible defaults so each test varies exactly one term.
    private func track(_ id: Int64,
                       bpm: Double? = 120,
                       camelot: CamelotKey? = CamelotKey(code: "8A"),
                       energy: Double? = 0.5,
                       embedding: [Float]? = [0.6, 0.8],
                       duration: Double = 240) -> TrackFeatures {
        TrackFeatures(trackID: id,
                      durationSec: duration,
                      bpm: bpm,
                      camelot: camelot,
                      energy: energy,
                      embedding: embedding)
    }

    private let constraints = SequencingConstraints()

    // MARK: - Composite cost (§28A.2)

    func testIdenticalTracksCostZero() {
        let a = track(1)
        let b = track(2)
        XCTAssertEqual(PlaylistSequencer.transitionCost(a, b, constraints), 0.0,
                       accuracy: 1e-12)
    }

    func testBPMJumpCostIsBoundedByMaxBPMJump() {
        let constraints = SequencingConstraints(maxBPMJump: 8)
        // Δ8 → 1.0, Δ4 → 0.5; other terms zero (identical everywhere else).
        XCTAssertEqual(PlaylistSequencer.transitionCost(track(1, bpm: 120),
                                                        track(2, bpm: 128),
                                                        constraints),
                       0.30 * 1.0, accuracy: 1e-12)
        XCTAssertEqual(PlaylistSequencer.transitionCost(track(1, bpm: 120),
                                                        track(2, bpm: 124),
                                                        constraints),
                       0.30 * 0.5, accuracy: 1e-12)
    }

    func testKeyCostScalesWithKeyStrictness() {
        let loose = SequencingConstraints(keyStrictness: 0)
        let strict = SequencingConstraints(keyStrictness: 1)
        // 8A → 8B is the relative partner: compatibility 0.9 → distance 0.1.
        XCTAssertEqual(PlaylistSequencer.transitionCost(track(1, camelot: .init(code: "8A")),
                                                        track(2, camelot: .init(code: "8B")),
                                                        strict),
                       0.25 * 0.1, accuracy: 1e-6)
        XCTAssertEqual(PlaylistSequencer.transitionCost(track(1, camelot: .init(code: "8A")),
                                                        track(2, camelot: .init(code: "8B")),
                                                        loose),
                       0.0, accuracy: 1e-12)
    }

    func testKeyCostIsFullForHarmonicallyFarKeys() {
        let strict = SequencingConstraints(keyStrictness: 1)
        // 8A → 5A is far on the wheel: compatibility 0.0 → distance 1.0.
        XCTAssertEqual(PlaylistSequencer.transitionCost(track(1, camelot: .init(code: "8A")),
                                                        track(2, camelot: .init(code: "5A")),
                                                        strict),
                       0.25 * 1.0, accuracy: 1e-12)
    }

    func testTimbreCostUsesCosineDistance() {
        // Orthogonal vectors → cosine distance 1.0.
        XCTAssertEqual(PlaylistSequencer.transitionCost(track(1, embedding: [1, 0]),
                                                        track(2, embedding: [0, 1]),
                                                        constraints),
                       0.30 * 1.0, accuracy: 1e-12)
        // Identical vectors → 0.
        XCTAssertEqual(PlaylistSequencer.transitionCost(track(1, embedding: [1, 0]),
                                                        track(2, embedding: [1, 0]),
                                                        constraints),
                       0.0, accuracy: 1e-12)
    }

    func testMissingEmbeddingIsNeutral() {
        let cost = PlaylistSequencer.transitionCost(track(1, embedding: nil),
                                                    track(2, embedding: nil),
                                                    constraints)
        // bpm/key/energy identical (zero) but the timbre term lands neutral.
        XCTAssertEqual(cost, 0.30 * 0.5, accuracy: 1e-12)
    }

    func testEnergyDropsPenalisedHarderThanRises() {
        // Rise of 0.1 → 0.1/0.35; drop of 0.1 → 0.1/0.20.
        let rise = PlaylistSequencer.transitionCost(track(1, energy: 0.5),
                                                    track(2, energy: 0.6),
                                                    constraints)
        let drop = PlaylistSequencer.transitionCost(track(1, energy: 0.6),
                                                    track(2, energy: 0.5),
                                                    constraints)
        XCTAssertEqual(rise, 0.15 * (0.1 / 0.35), accuracy: 1e-12)
        XCTAssertEqual(drop, 0.15 * (0.1 / 0.20), accuracy: 1e-12)
        XCTAssertGreaterThan(drop, rise)
    }

    func testLargeEnergyStepClampsAtOne() {
        XCTAssertEqual(PlaylistSequencer.transitionCost(track(1, energy: 0.0),
                                                        track(2, energy: 1.0),
                                                        constraints),
                       0.15 * 1.0, accuracy: 1e-12)
    }

    func testMissingBPMIsNeutral() {
        let cost = PlaylistSequencer.transitionCost(track(1, bpm: nil),
                                                    track(2, bpm: nil),
                                                    constraints)
        XCTAssertEqual(cost, 0.30 * 0.5, accuracy: 1e-12)
    }

    func testCostIsDeterministic() {
        let pairs: [(TrackFeatures, TrackFeatures)] = [
            (track(1), track(2)),
            (track(1, bpm: 124), track(2, bpm: 131, camelot: .init(code: "9A"),
                                       energy: 0.7, embedding: [0.2, 0.9])),
            (track(1, energy: nil, embedding: nil), track(2, bpm: nil, camelot: nil)),
        ]
        for pair in pairs {
            XCTAssertEqual(PlaylistSequencer.transitionCost(pair.0, pair.1, constraints),
                           PlaylistSequencer.transitionCost(pair.0, pair.1, constraints),
                           accuracy: 1e-15)
        }
    }

    // MARK: - Camelot distance (§28A.2, plan §2.3)

    func testCamelotDistanceGrades() {
        func d(_ a: String, _ b: String) -> Double {
            Camelot.distance(.init(code: a), .init(code: b))
        }
        // Tolerance 1e-6: the distance is `1 − compatibility`, and
        // compatibility is a Float, so the values carry Float epsilon.
        XCTAssertEqual(d("8A", "8A"), 0.0, accuracy: 1e-6)       // identical
        XCTAssertEqual(d("8A", "8B"), 0.1, accuracy: 1e-6)       // relative
        XCTAssertEqual(d("8A", "7A"), 0.3, accuracy: 1e-6)       // ±1 same letter
        XCTAssertEqual(d("8A", "2A"), 0.5, accuracy: 1e-6)       // energy boost
        XCTAssertEqual(d("8A", "5A"), 1.0, accuracy: 1e-6)       // far
        XCTAssertEqual(Camelot.distance(nil, .init(code: "8A")), 0.5, accuracy: 1e-12)
        XCTAssertEqual(Camelot.distance(.init(code: "8A"), nil), 0.5, accuracy: 1e-12)
        XCTAssertEqual(Camelot.distance(nil, nil), 0.5, accuracy: 1e-12)
    }

    // MARK: - SequencingConstraints (§14.3 constraintsJSON)

    func testConstraintsJSONRoundTripsByteExact() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let constraints = SequencingConstraints(minArtistGap: 2, maxBPMJump: 10,
                                                keyStrictness: 0.8,
                                                bpmRange: 118...132,
                                                excludeGenres: ["shouty vocals"])
        let encoded = try encoder.encode(constraints)
        let decoded = try JSONDecoder().decode(SequencingConstraints.self, from: encoded)
        XCTAssertEqual(decoded, constraints)
        XCTAssertEqual(try encoder.encode(decoded), encoded)
    }

    func testConstraintsBpmRangeRoundTrip() {
        let constraints = SequencingConstraints(bpmRange: 116...134)
        XCTAssertEqual(constraints.bpmRange, 116...134)
        var copy = constraints
        copy.bpmRange = 120...128
        XCTAssertEqual(copy.bpmLo, 120)
        XCTAssertEqual(copy.bpmHi, 128)
    }
}
