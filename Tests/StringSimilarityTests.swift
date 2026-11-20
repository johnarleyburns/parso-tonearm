import Testing
@testable import TonearmCore

@Suite struct StringSimilarityTests {

    @Test func testNormalizeFoldsDiacriticsAndPunctuation() {
        #expect(StringSimilarity.normalize("Bodzín!") == "bodzin")
        #expect(StringSimilarity.normalize("El Búho") == "el buho")
        #expect(StringSimilarity.normalize("A.C.-D.C.") == "a c d c")
    }

    @Test func testRatioIdenticalAndDifferent() {
        #expect(abs(StringSimilarity.ratio("Solomun", "solomun") - 1.0) <= 0.0001)
        #expect(StringSimilarity.ratio("Bodzin", "Bodzín") > 0.99)
        #expect(StringSimilarity.ratio("Solomun", "Skrillex") < 0.5)
    }

    @Test func testTokensContainedRequiresAllNeedleTokens() {
        #expect(StringSimilarity.tokensContained(needle: "Solomun",
                                                       in: "Skrillex & Solomun"))
        #expect(StringSimilarity.tokensContained(needle: "Stephan Bodzin",
                                                       in: "Stephan Bodzin"))
        #expect(!StringSimilarity.tokensContained(needle: "Stephan Bodzin",
                                                        in: "Solomun"))
    }

    @Test func testTokensContainedRejectsShortNoise() {
        // Single short token that doesn't appear -> not contained.
        #expect(!StringSimilarity.tokensContained(needle: "workout rocky",
                                                        in: "Normani"))
    }

    @Test func testTokenOverlapFraction() {
        #expect(
            abs(StringSimilarity.tokenOverlap(needle: "workout rocky motivation",
                                                     haystack: "Motivation") - (1.0 / 3.0)) <= 0.01)
    }
}
