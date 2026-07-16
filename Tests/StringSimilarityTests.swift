import XCTest
@testable import TonearmCore

final class StringSimilarityTests: XCTestCase {

    func testNormalizeFoldsDiacriticsAndPunctuation() {
        XCTAssertEqual(StringSimilarity.normalize("Bodzín!"), "bodzin")
        XCTAssertEqual(StringSimilarity.normalize("El Búho"), "el buho")
        XCTAssertEqual(StringSimilarity.normalize("A.C.-D.C."), "a c d c")
    }

    func testRatioIdenticalAndDifferent() {
        XCTAssertEqual(StringSimilarity.ratio("Solomun", "solomun"), 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(StringSimilarity.ratio("Bodzin", "Bodzín"), 0.99)
        XCTAssertLessThan(StringSimilarity.ratio("Solomun", "Skrillex"), 0.5)
    }

    func testTokensContainedRequiresAllNeedleTokens() {
        XCTAssertTrue(StringSimilarity.tokensContained(needle: "Solomun",
                                                       in: "Skrillex & Solomun"))
        XCTAssertTrue(StringSimilarity.tokensContained(needle: "Stephan Bodzin",
                                                       in: "Stephan Bodzin"))
        XCTAssertFalse(StringSimilarity.tokensContained(needle: "Stephan Bodzin",
                                                        in: "Solomun"))
    }

    func testTokensContainedRejectsShortNoise() {
        // Single short token that doesn't appear -> not contained.
        XCTAssertFalse(StringSimilarity.tokensContained(needle: "workout rocky",
                                                        in: "Normani"))
    }

    func testTokenOverlapFraction() {
        XCTAssertEqual(StringSimilarity.tokenOverlap(needle: "workout rocky motivation",
                                                     haystack: "Motivation"),
                       1.0 / 3.0, accuracy: 0.01)
    }
}
