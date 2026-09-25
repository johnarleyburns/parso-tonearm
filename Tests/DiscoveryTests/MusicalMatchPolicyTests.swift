#if !os(watchOS)
import ParsoAudioAnalysis
import XCTest

@testable import TonearmDiscovery

final class MusicalMatchPolicyTests: XCTestCase {
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
}
#endif
