#if !os(watchOS)
import XCTest

@testable import TonearmDiscovery

/// Plan §9: `Query` is a Codable validated value. Oversize / malformed input
/// yields an actionable validation result, never a silently-clamped query.
final class DiscoverySearchQueryTests: XCTestCase {
    private func validate(_ q: DiscoverySearchQuery) -> [QueryValidationIssue] {
        switch ValidatedQuery.validate(q) {
        case .success: return []
        case .failure(let f): return f.issues
        }
    }

    func testDefaultsAreValidAndNormalized() throws {
        let out = ValidatedQuery.validate(
            DiscoverySearchQuery(text: "  gentle   acoustic  guitar \n"))
        guard case .success(let v) = out else { return XCTFail("expected success") }
        XCTAssertEqual(v.text, "gentle acoustic guitar")
        XCTAssertEqual(v.limit, 50)
        XCTAssertNil(v.bpmRange)
        XCTAssertFalse(v.hasHardMusicalFilter)
        XCTAssertTrue(v.hasText)
    }

    func testTextOverFiveHundredCharsRejected() {
        let issues = validate(DiscoverySearchQuery(text: String(repeating: "a", count: 501)))
        XCTAssertEqual(issues, [.textTooLong(limit: 500, actual: 501)])
    }

    func testTooManyRefinements() {
        let issues = validate(
            DiscoverySearchQuery(
                text: "x", positiveRefinements: Array(repeating: "a", count: 5),
                negativeRefinements: Array(repeating: "b", count: 4)))
        XCTAssertEqual(issues, [.tooManyRefinements(limit: 8, actual: 9)])
    }

    func testRefinementTermTooLong() {
        let long = String(repeating: "z", count: 101)
        let issues = validate(DiscoverySearchQuery(text: "x", positiveRefinements: [long]))
        XCTAssertEqual(issues, [.refinementTermTooLong(limit: 100, actual: 101, term: long)])
    }

    func testReversedBPMRejected() {
        let issues = validate(DiscoverySearchQuery(text: "x", bpmMin: 140, bpmMax: 100))
        XCTAssertEqual(issues, [.bpmReversed(min: 140, max: 100)])
    }

    func testNonFiniteBPMRejected() {
        let issues = validate(DiscoverySearchQuery(text: "x", bpmMin: .nan, bpmMax: 120))
        XCTAssertEqual(issues, [.bpmNotFinite])
    }

    func testNegativeBPMRejected() {
        let issues = validate(DiscoverySearchQuery(text: "x", bpmMin: -10, bpmMax: 20))
        XCTAssertEqual(issues, [.bpmNegative(-10)])
    }

    func testInvalidKeyCodeRejected() {
        let issues = validate(DiscoverySearchQuery(text: "x", compatibleKey: "99Z"))
        XCTAssertEqual(issues, [.invalidKeyCode("99Z")])
    }

    func testValidKeyCodeParsed() {
        guard case .success(let v) = ValidatedQuery.validate(
            DiscoverySearchQuery(text: "x", compatibleKey: "8A"))
        else { return XCTFail() }
        XCTAssertEqual(v.compatibleKey?.code, "8A")
        XCTAssertTrue(v.hasHardMusicalFilter)
    }

    func testLimitOutOfRange() {
        XCTAssertEqual(
            validate(DiscoverySearchQuery(text: "x", limit: 0)),
            [.limitOutOfRange(min: 1, max: 200, actual: 0)])
        XCTAssertEqual(
            validate(DiscoverySearchQuery(text: "x", limit: 201)),
            [.limitOutOfRange(min: 1, max: 200, actual: 201)])
    }

    func testMultipleIssuesReportedTogether() {
        let issues = validate(
            DiscoverySearchQuery(
                text: String(repeating: "a", count: 600), bpmMin: 200, bpmMax: 100, limit: 999))
        XCTAssertTrue(issues.contains(.textTooLong(limit: 500, actual: 600)))
        XCTAssertTrue(issues.contains(.bpmReversed(min: 200, max: 100)))
        XCTAssertTrue(issues.contains(.limitOutOfRange(min: 1, max: 200, actual: 999)))
    }

    func testCodableRoundTrip() throws {
        let q = DiscoverySearchQuery(
            text: "warm pads", positiveRefinements: ["lush"], negativeRefinements: ["vocals"],
            sourceIDs: [1, 2], playlistID: 7, bpmMin: 110, bpmMax: 124, compatibleKey: "9B",
            limit: 25)
        let data = try JSONEncoder().encode(q)
        let back = try JSONDecoder().decode(DiscoverySearchQuery.self, from: data)
        XCTAssertEqual(q, back)
    }

    func testExplicitEmptyScopePreserved() {
        guard case .success(let v) = ValidatedQuery.validate(
            DiscoverySearchQuery(text: "x", sourceIDs: []))
        else { return XCTFail() }
        XCTAssertEqual(v.sourceIDs, [])
    }
}
#endif
