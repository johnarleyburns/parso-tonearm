#if !os(watchOS)
import ParsoAudioAnalysis
import XCTest
import TonearmCore

@testable import TonearmDiscovery

final class MusicalMatchPolicyTests: XCTestCase {
    func testMoodQueuePreservesOrderAndOnlyIncludesConsecutiveMixCompatibleTracks() {
        let info: [Int64: DJLoadTrackInfo] = [
            1: .init(bpm: 100, camelotKey: "8A"), 2: .init(bpm: 108, camelotKey: "9A"),
            3: .init(bpm: 92, camelotKey: "8A"), 4: .init(bpm: 108, camelotKey: "9B"),
            5: .init(bpm: .nan, camelotKey: "9B"), 6: .init(bpm: 108, camelotKey: nil)]
        XCTAssertEqual(MusicalMatchPolicy.queueTrackIDs([1, 2, 3, 4, 5, 6, 1], metadata: info), [1, 2, 4])
        XCTAssertTrue(MusicalMatchPolicy.queueTrackIDs([5, 6], metadata: info).isEmpty)
        XCTAssertEqual(MusicalMatchPolicy.queueTrackIDs([3, 2], metadata: info, startingFrom: 1), [3])
    }
    func testCompatibleKeysIncludeSameAdjacentWrapAndRelative() throws {
        let reference = try XCTUnwrap(CamelotKey(code: "1A"))
        let codes = MusicalMatchPolicy.compatibleKeyCodes(for: reference)
        XCTAssertEqual(codes, ["1A", "1B", "2A", "12A"])
    }

    func testBPMRangeIsRelativeAndIncludesEightPercentBoundary() throws {
        let range = try XCTUnwrap(MusicalMatchPolicy.bpmRange(for: 125))
        XCTAssertEqual(range.lowerBound, 115, accuracy: 0.000001)
        XCTAssertEqual(range.upperBound, 135, accuracy: 0.000001)
        XCTAssertNotNil(MusicalMatchPolicy.bpmDifferenceRatio(candidate: 135, reference: 125))
        XCTAssertTrue(MusicalMatchPolicy.matches(
            candidateBPM: 135,
            candidateKey: CamelotKey(code: "12A"),
            reference: MusicalMatchReference(bpm: 125, camelot: try XCTUnwrap(CamelotKey(code: "1A")))))
    }

    func testJustOutsideBPMOrKeyDoesNotMatch() throws {
        let reference = MusicalMatchReference(
            bpm: 125, camelot: try XCTUnwrap(CamelotKey(code: "1A")))
        XCTAssertFalse(MusicalMatchPolicy.matches(
            candidateBPM: 135.01, candidateKey: CamelotKey(code: "1A"), reference: reference))
        XCTAssertFalse(MusicalMatchPolicy.matches(
            candidateBPM: 125, candidateKey: CamelotKey(code: "2B"), reference: reference))
        XCTAssertFalse(MusicalMatchPolicy.matches(
            candidateBPM: nil, candidateKey: CamelotKey(code: "1A"), reference: reference))
        XCTAssertFalse(MusicalMatchPolicy.matches(
            candidateBPM: 125, candidateKey: nil, reference: reference))
    }

    func testInvalidBPMValuesCannotCreateAMatchRange() {
        XCTAssertNil(MusicalMatchPolicy.bpmRange(for: 0))
        XCTAssertNil(MusicalMatchPolicy.bpmRange(for: .nan))
        XCTAssertNil(MusicalMatchPolicy.bpmDifferenceRatio(candidate: .infinity, reference: 125))
    }

    func testEnergyWithinToleranceMatchesAndOutsideDoesNot() throws {
        let key = try XCTUnwrap(CamelotKey(code: "1A"))
        let reference = MusicalMatchReference(bpm: 125, camelot: key, energy: 5)
        XCTAssertTrue(MusicalMatchPolicy.matches(
            candidateBPM: 125, candidateKey: key, candidateEnergy: 7, reference: reference),
            "2.0 away is exactly at the tolerance boundary")
        XCTAssertFalse(MusicalMatchPolicy.matches(
            candidateBPM: 125, candidateKey: key, candidateEnergy: 7.1, reference: reference),
            "just past the tolerance boundary must not match")
    }

    func testMissingEnergyOnEitherSideNeverBlocksAMatch() throws {
        let key = try XCTUnwrap(CamelotKey(code: "1A"))
        let referenceWithEnergy = MusicalMatchReference(bpm: 125, camelot: key, energy: 5)
        let referenceWithoutEnergy = MusicalMatchReference(bpm: 125, camelot: key)
        XCTAssertTrue(MusicalMatchPolicy.matches(
            candidateBPM: 125, candidateKey: key, candidateEnergy: nil, reference: referenceWithEnergy),
            "a candidate with no stored energy must not be excluded on that basis")
        XCTAssertTrue(MusicalMatchPolicy.matches(
            candidateBPM: 125, candidateKey: key, candidateEnergy: 9.9, reference: referenceWithoutEnergy),
            "a reference with no stored energy must not gate any candidate")
    }

    func testEnergyMismatchCannotRescueABPMOrKeyMismatch() throws {
        let key = try XCTUnwrap(CamelotKey(code: "1A"))
        let reference = MusicalMatchReference(bpm: 125, camelot: key, energy: 5)
        XCTAssertFalse(MusicalMatchPolicy.matches(
            candidateBPM: 135.01, candidateKey: key, candidateEnergy: 5, reference: reference),
            "identical energy must not override a BPM mismatch")
    }

    func testMoodQueueEnergyByIDAppliesTheSameNilSafeGate() {
        let info: [Int64: DJLoadTrackInfo] = [
            1: .init(bpm: 100, camelotKey: "8A"), 2: .init(bpm: 108, camelotKey: "9A"),
            3: .init(bpm: 108, camelotKey: "9A")]
        let energies: [Int64: Double] = [1: 5, 2: 5.5, 3: 9]
        XCTAssertEqual(
            MusicalMatchPolicy.queueTrackIDs([1, 2, 3], metadata: info, energyByID: energies), [1, 2],
            "track 3 is BPM/key compatible but its energy is too far from track 2's")
    }
}
#endif
