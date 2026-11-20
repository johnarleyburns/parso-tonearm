#if !os(watchOS)
import Foundation
import Testing

@testable import TonearmDiscovery

/// Plan §9: `Query` is a Codable validated value. Oversize / malformed input
/// yields an actionable validation result, never a silently-clamped query.
@Suite struct DiscoverySearchQueryTests {
    private func validate(_ q: DiscoverySearchQuery) -> [QueryValidationIssue] {
        switch ValidatedQuery.validate(q) {
        case .success: return []
        case .failure(let f): return f.issues
        }
    }

    @Test func testDefaultsAreValidAndNormalized() throws {
        let out = ValidatedQuery.validate(
            DiscoverySearchQuery(text: "  gentle   acoustic  guitar \n"))
        guard case .success(let v) = out else { Issue.record("expected success"); return }
        #expect(v.text == "gentle acoustic guitar")
        #expect(v.limit == 50)
        #expect(v.bpmRange == nil)
        #expect(!v.hasHardMusicalFilter)
        #expect(v.hasText)
    }

    @Test func testTextOverFiveHundredCharsRejected() {
        let issues = validate(DiscoverySearchQuery(text: String(repeating: "a", count: 501)))
        #expect(issues == [.textTooLong(limit: 500, actual: 501)])
    }

    @Test func testTooManyRefinements() {
        let issues = validate(
            DiscoverySearchQuery(
                text: "x", positiveRefinements: Array(repeating: "a", count: 5),
                negativeRefinements: Array(repeating: "b", count: 4)))
        #expect(issues == [.tooManyRefinements(limit: 8, actual: 9)])
    }

    @Test func testRefinementTermTooLong() {
        let long = String(repeating: "z", count: 101)
        let issues = validate(DiscoverySearchQuery(text: "x", positiveRefinements: [long]))
        #expect(issues == [.refinementTermTooLong(limit: 100, actual: 101, term: long)])
    }

    @Test func testReversedBPMRejected() {
        let issues = validate(DiscoverySearchQuery(text: "x", bpmMin: 140, bpmMax: 100))
        #expect(issues == [.bpmReversed(min: 140, max: 100)])
    }

    @Test func testNonFiniteBPMRejected() {
        let issues = validate(DiscoverySearchQuery(text: "x", bpmMin: .nan, bpmMax: 120))
        #expect(issues == [.bpmNotFinite])
    }

    @Test func testNegativeBPMRejected() {
        let issues = validate(DiscoverySearchQuery(text: "x", bpmMin: -10, bpmMax: 20))
        #expect(issues == [.bpmNegative(-10)])
    }

    @Test func testInvalidKeyCodeRejected() {
        let issues = validate(DiscoverySearchQuery(text: "x", compatibleKey: "99Z"))
        #expect(issues == [.invalidKeyCode("99Z")])
    }

    @Test func testValidKeyCodeParsed() {
        guard case .success(let v) = ValidatedQuery.validate(
            DiscoverySearchQuery(text: "x", compatibleKey: "8A"))
        else { Issue.record(); return }
        #expect(v.compatibleKey?.code == "8A")
        #expect(v.hasHardMusicalFilter)
    }

    @Test func testLimitOutOfRange() {
        #expect(
            validate(DiscoverySearchQuery(text: "x", limit: 0)) ==
            [.limitOutOfRange(min: 1, max: 200, actual: 0)])
        #expect(
            validate(DiscoverySearchQuery(text: "x", limit: 201)) ==
            [.limitOutOfRange(min: 1, max: 200, actual: 201)])
    }

    @Test func testMultipleIssuesReportedTogether() {
        let issues = validate(
            DiscoverySearchQuery(
                text: String(repeating: "a", count: 600), bpmMin: 200, bpmMax: 100, limit: 999))
        #expect(issues.contains(.textTooLong(limit: 500, actual: 600)))
        #expect(issues.contains(.bpmReversed(min: 200, max: 100)))
        #expect(issues.contains(.limitOutOfRange(min: 1, max: 200, actual: 999)))
    }

    @Test func testCodableRoundTrip() throws {
        let q = DiscoverySearchQuery(
            text: "warm pads", positiveRefinements: ["lush"], negativeRefinements: ["vocals"],
            sourceIDs: [1, 2], playlistID: 7, bpmMin: 110, bpmMax: 124, compatibleKey: "9B",
            limit: 25)
        let data = try JSONEncoder().encode(q)
        let back = try JSONDecoder().decode(DiscoverySearchQuery.self, from: data)
        #expect(q == back)
    }

    @Test func testExplicitEmptyScopePreserved() {
        guard case .success(let v) = ValidatedQuery.validate(
            DiscoverySearchQuery(text: "x", sourceIDs: []))
        else { Issue.record(); return }
        #expect(v.sourceIDs == [])
    }
}
#endif
