import XCTest

@testable import TonearmDJ

final class ArcTests: XCTestCase {

    // MARK: - Closed forms (§28A.5)

    func testSteadyIsFlatAtItsLevel() {
        let arc = EnergyArc.steady(level: 0.4)
        for t in [0.0, 0.25, 0.5, 0.75, 1.0] {
            XCTAssertEqual(arc.value(at: t), 0.4, accuracy: 1e-12)
        }
    }

    func testBuildIsAGentleScurve() {
        let arc = EnergyArc.build
        XCTAssertEqual(arc.value(at: 0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(arc.value(at: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(arc.value(at: 1), 1.0, accuracy: 1e-12)
        // Monotone rise over the middle.
        XCTAssertLessThan(arc.value(at: 0.25), arc.value(at: 0.5))
        XCTAssertLessThan(arc.value(at: 0.5), arc.value(at: 0.75))
    }

    func testPeakAndReleaseRisesToPeakThenFalls() {
        let arc = EnergyArc.peakAndRelease(peakAt: 0.7)
        XCTAssertEqual(arc.value(at: 0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(arc.value(at: 0.35), 0.5, accuracy: 1e-12)
        XCTAssertEqual(arc.value(at: 0.7), 1.0, accuracy: 1e-12)
        XCTAssertEqual(arc.value(at: 0.85), 0.5, accuracy: 1e-12)
        XCTAssertEqual(arc.value(at: 1), 0.0, accuracy: 1e-12)
    }

    func testWindDownIsTheMirrorOfBuild() {
        let arc = EnergyArc.windDown
        XCTAssertEqual(arc.value(at: 0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(arc.value(at: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(arc.value(at: 1), 0.0, accuracy: 1e-12)
    }

    func testWaveIsSinusoidal() {
        let arc = EnergyArc.wave(cycles: 1)
        XCTAssertEqual(arc.value(at: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(arc.value(at: 0.25), 1.0, accuracy: 1e-9)
        XCTAssertEqual(arc.value(at: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(arc.value(at: 0.75), 0.0, accuracy: 1e-9)
        XCTAssertEqual(arc.value(at: 1), 0.5, accuracy: 1e-9)
    }

    func testCustomInterpolatesPiecewiseLinearly() {
        let ramp = EnergyArc.custom(points: [0, 1])
        XCTAssertEqual(ramp.value(at: 0), 0.0, accuracy: 1e-12)
        XCTAssertEqual(ramp.value(at: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ramp.value(at: 1), 1.0, accuracy: 1e-12)

        let peak = EnergyArc.custom(points: [0, 1, 0])
        XCTAssertEqual(peak.value(at: 0.25), 0.5, accuracy: 1e-12)
        XCTAssertEqual(peak.value(at: 0.5), 1.0, accuracy: 1e-12)
        XCTAssertEqual(peak.value(at: 0.75), 0.5, accuracy: 1e-12)
    }

    func testCustomEdgeCases() {
        XCTAssertEqual(EnergyArc.custom(points: []).value(at: 0.3), 0.5, accuracy: 1e-12)
        XCTAssertEqual(EnergyArc.custom(points: [0.8]).value(at: 0.9), 0.8, accuracy: 1e-12)
    }

    func testValuesStayInUnitRangeAcrossTheDomain() {
        let arcs: [EnergyArc] = [
            .steady(level: 1.2),
            .steady(level: -0.3),
            .build,
            .peakAndRelease(peakAt: 0.7),
            .peakAndRelease(peakAt: 1.0),
            .windDown,
            .wave(cycles: 2.5),
            .custom(points: [0.2, 1.4, -0.1, 0.9]),
        ]
        var t = 0.0
        while t <= 1.0 {
            for arc in arcs {
                let value = arc.value(at: t)
                XCTAssertTrue((0...1).contains(value),
                              "arc \(arc.kindCode) out of range at t=\(t): \(value)")
            }
            t += 0.013
        }
    }

    func testValuesArePureAndDeterministic() {
        let arc = EnergyArc.peakAndRelease(peakAt: 0.7)
        for t in stride(from: 0.0, through: 1.0, by: 0.05) {
            XCTAssertEqual(arc.value(at: t), arc.value(at: t), accuracy: 1e-15)
        }
    }

    // MARK: - Codable

    func testCodableRoundTripsEveryCase() throws {
        let arcs: [EnergyArc] = [
            .steady(level: 0.4),
            .build,
            .peakAndRelease(peakAt: 0.7),
            .windDown,
            .wave(cycles: 1.5),
            .custom(points: [0.1, 0.8, 0.3]),
        ]
        for arc in arcs {
            let data = try JSONEncoder().encode(arc)
            let decoded = try JSONDecoder().decode(EnergyArc.self, from: data)
            XCTAssertEqual(decoded, arc, "round-trip failed for \(arc.kindCode)")
        }
    }

    // MARK: - §14.3 row round-trip (arcKind + arcPointsJSON)

    func testKindCodeAndPointsJSONRoundTrip() {
        let arcs: [EnergyArc] = [
            .steady(level: 0.35),
            .build,
            .peakAndRelease(peakAt: 0.62),
            .windDown,
            .wave(cycles: 2.0),
            .custom(points: [0.0, 0.5, 1.0]),
        ]
        for arc in arcs {
            guard let decoded = EnergyArc.from(kindCode: arc.kindCode,
                                               pointsJSON: arc.pointsJSON) else {
                XCTFail("failed to rebuild \(arc.kindCode)")
                continue
            }
            XCTAssertEqual(decoded, arc, "row round-trip failed for \(arc.kindCode)")
        }
    }

    func testKindCodeMatchesDdlValues() {
        XCTAssertEqual(EnergyArc.steady(level: 0.5).kindCode, "steady")
        XCTAssertEqual(EnergyArc.build.kindCode, "build")
        XCTAssertEqual(EnergyArc.peakAndRelease(peakAt: 0.7).kindCode, "peakRelease")
        XCTAssertEqual(EnergyArc.windDown.kindCode, "windDown")
        XCTAssertEqual(EnergyArc.wave(cycles: 1).kindCode, "wave")
        XCTAssertEqual(EnergyArc.custom(points: []).kindCode, "custom")
    }

    func testPointsJSONIsByteExact() {
        let arc = EnergyArc.peakAndRelease(peakAt: 0.62)
        XCTAssertEqual(arc.pointsJSON, arc.pointsJSON)
        // Canonical form is stable and readable.
        XCTAssertEqual(arc.pointsJSON, #"{"peakAt":0.62}"#)
        XCTAssertEqual(EnergyArc.build.pointsJSON, "{}")
    }

    func testFromRejectsUnknownKind() {
        XCTAssertNil(EnergyArc.from(kindCode: "banana", pointsJSON: nil))
    }

    // MARK: - EmpiricalEnergyCDF (§28A.5)

    func testCDFRanksBasic() {
        let ranks = EmpiricalEnergyCDF.ranks(energies: [
            (trackID: 1, energy: 2.0), (trackID: 2, energy: 4.0),
            (trackID: 3, energy: 6.0), (trackID: 4, energy: 8.0),
            (trackID: 5, energy: 10.0),
        ])
        XCTAssertEqual(ranks[1] ?? -1, 0.2, accuracy: 1e-12)
        XCTAssertEqual(ranks[2] ?? -1, 0.4, accuracy: 1e-12)
        XCTAssertEqual(ranks[3] ?? -1, 0.6, accuracy: 1e-12)
        XCTAssertEqual(ranks[4] ?? -1, 0.8, accuracy: 1e-12)
        XCTAssertEqual(ranks[5] ?? -1, 1.0, accuracy: 1e-12)
    }

    func testCDFRanksTiesShareTheUpperRank() {
        let ranks = EmpiricalEnergyCDF.ranks(energies: [
            (trackID: 1, energy: 3.0), (trackID: 2, energy: 3.0),
            (trackID: 3, energy: 5.0),
        ])
        XCTAssertEqual(ranks[1] ?? -1, ranks[2] ?? -1, accuracy: 1e-12)
        XCTAssertEqual(ranks[1] ?? -1, 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(ranks[3] ?? -1, 1.0, accuracy: 1e-12)
    }

    func testCDFRanksMissingEnergyIsNeutral() {
        let ranks = EmpiricalEnergyCDF.ranks(energies: [
            (trackID: 1, energy: nil), (trackID: 2, energy: 5.0),
        ])
        XCTAssertEqual(ranks[1] ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(ranks[2] ?? -1, 1.0, accuracy: 1e-12)
    }

    func testCDFRanksEmptySetYieldsNeutralForAll() {
        let ranks = EmpiricalEnergyCDF.ranks(energies: [
            (trackID: 1, energy: nil), (trackID: 2, energy: nil),
        ])
        XCTAssertEqual(ranks.count, 2)
        XCTAssertEqual(ranks[1] ?? -1, 0.5, accuracy: 1e-12)
        XCTAssertEqual(ranks[2] ?? -1, 0.5, accuracy: 1e-12)
    }

    func testCDFRanksAreDeterministicAndTrackOrderingIndependent() {
        let energies: [(trackID: Int64, energy: Double?)] = [
            (3, 7.0), (1, 4.0), (2, 4.0), (5, 9.0), (4, 2.0),
        ]
        let first = EmpiricalEnergyCDF.ranks(energies: energies)
        let shuffled = EmpiricalEnergyCDF.ranks(energies: energies.reversed())
        XCTAssertEqual(first, shuffled)
    }
}
