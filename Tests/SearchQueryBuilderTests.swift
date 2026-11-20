import Testing

@testable import TonearmCore

@Suite struct SearchQueryBuilderTests {

    @Test func testEmptyWhitespaceStarAndQuoteOnlyQueriesReturnNil() {
        #expect(SearchQueryBuilder.matchExpression(for: "") == nil)
        #expect(SearchQueryBuilder.matchExpression(for: "    \n\t") == nil)
        #expect(SearchQueryBuilder.matchExpression(for: "*") == nil)
        #expect(SearchQueryBuilder.matchExpression(for: "\"") == nil)
        #expect(SearchQueryBuilder.matchExpression(for: "*** \" ***") == nil)
    }

    @Test func testBuildsQuotedPrefixTerms() {
        #expect(
            SearchQueryBuilder.matchExpression(for: "Miles Blue") ==
            "\"Miles\"* \"Blue\"*"
        )
    }

    @Test func testInjectionOperatorsBecomeQuotedLiteralTerms() {
        #expect(
            SearchQueryBuilder.matchExpression(for: "title OR artist NOT genre") ==
            "\"title\"* \"OR\"* \"artist\"* \"NOT\"* \"genre\"*"
        )
        #expect(
            SearchQueryBuilder.matchExpression(for: "name NEAR/5 album") ==
            "\"name\"* \"NEAR\"* \"5\"* \"album\"*"
        )
    }

    @Test func testUnbalancedQuotesAndFtsPunctuationAreSeparators() {
        #expect(
            SearchQueryBuilder.matchExpression(for: "\"kind of blue") ==
            "\"kind\"* \"of\"* \"blue\"*"
        )
        #expect(
            SearchQueryBuilder.matchExpression(for: "artist:beatles {album} -live") ==
            "\"artist\"* \"beatles\"* \"album\"* \"live\"*"
        )
    }

    @Test func testCJKAndDiacriticsArePreservedForUnicode61Tokenization() {
        #expect(
            SearchQueryBuilder.matchExpression(for: "Álvaro 東京事変") ==
            "\"Álvaro\"* \"東京事変\"*"
        )
    }

    @Test func testVeryLongQueriesAreCapped() {
        let longTerm = String(repeating: "a", count: 200)
        let manyTerms = (0..<80).map { "term\($0)" }.joined(separator: " ")

        let single = SearchQueryBuilder.matchExpression(for: longTerm)
        #expect(single == "\"\(String(repeating: "a", count: SearchQueryBuilder.maxScalarsPerTerm))\"*")

        let terms = SearchQueryBuilder.tokenize(manyTerms)
        #expect(terms.count == 80)
        let expression = SearchQueryBuilder.matchExpression(for: manyTerms)
        #expect(expression?.components(separatedBy: " ").count == SearchQueryBuilder.maxTerms)
        #expect(expression?.contains("\"term31\"*") == true)
        #expect(expression?.contains("\"term32\"*") == false)
    }
}
