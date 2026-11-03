import XCTest
@testable import TonearmCore

final class FindBlendSearchTests: XCTestCase {
    func testBlankQueryYieldsNothing() {
        XCTAssertTrue(FindBlendSearch.results(query: "  ", saved: []).isEmpty)
    }

    func testNoMatchIsEmptyAndDeterministic() {
        XCTAssertTrue(FindBlendSearch.results(query: "zzzqqq", saved: []).isEmpty)
    }

    func testSavedBlendMatchingTitleIsReturned() {
        let doc = BlendDocument(title: "Morning Mix", origin: .manualQueue, occurrences: [])
        let results = FindBlendSearch.results(query: "morning", saved: [doc])
        guard case .saved(let blend) = results.first else { return XCTFail("expected a saved match") }
        XCTAssertEqual(blend.title, "Morning Mix")
        XCTAssertEqual(results.count, 1)
    }
}
