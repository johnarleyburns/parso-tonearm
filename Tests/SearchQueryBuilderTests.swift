import XCTest

@testable import Tonearm

final class SearchQueryBuilderTests: XCTestCase {

    func testEmptyWhitespaceStarAndQuoteOnlyQueriesReturnNil() {
        XCTAssertNil(SearchQueryBuilder.matchExpression(for: ""))
        XCTAssertNil(SearchQueryBuilder.matchExpression(for: "    \n\t"))
        XCTAssertNil(SearchQueryBuilder.matchExpression(for: "*"))
        XCTAssertNil(SearchQueryBuilder.matchExpression(for: "\""))
        XCTAssertNil(SearchQueryBuilder.matchExpression(for: "*** \" ***"))
    }

    func testBuildsQuotedPrefixTerms() {
        XCTAssertEqual(
            SearchQueryBuilder.matchExpression(for: "Miles Blue"),
            "\"Miles\"* \"Blue\"*"
        )
    }

    func testInjectionOperatorsBecomeQuotedLiteralTerms() {
        XCTAssertEqual(
            SearchQueryBuilder.matchExpression(for: "title OR artist NOT genre"),
            "\"title\"* \"OR\"* \"artist\"* \"NOT\"* \"genre\"*"
        )
        XCTAssertEqual(
            SearchQueryBuilder.matchExpression(for: "name NEAR/5 album"),
            "\"name\"* \"NEAR\"* \"5\"* \"album\"*"
        )
    }

    func testUnbalancedQuotesAndFtsPunctuationAreSeparators() {
        XCTAssertEqual(
            SearchQueryBuilder.matchExpression(for: "\"kind of blue"),
            "\"kind\"* \"of\"* \"blue\"*"
        )
        XCTAssertEqual(
            SearchQueryBuilder.matchExpression(for: "artist:beatles {album} -live"),
            "\"artist\"* \"beatles\"* \"album\"* \"live\"*"
        )
    }

    func testCJKAndDiacriticsArePreservedForUnicode61Tokenization() {
        XCTAssertEqual(
            SearchQueryBuilder.matchExpression(for: "Álvaro 東京事変"),
            "\"Álvaro\"* \"東京事変\"*"
        )
    }

    func testVeryLongQueriesAreCapped() {
        let longTerm = String(repeating: "a", count: 200)
        let manyTerms = (0..<80).map { "term\($0)" }.joined(separator: " ")

        let single = SearchQueryBuilder.matchExpression(for: longTerm)
        XCTAssertEqual(single, "\"\(String(repeating: "a", count: SearchQueryBuilder.maxScalarsPerTerm))\"*")

        let terms = SearchQueryBuilder.tokenize(manyTerms)
        XCTAssertEqual(terms.count, 80)
        let expression = SearchQueryBuilder.matchExpression(for: manyTerms)
        XCTAssertEqual(expression?.components(separatedBy: " ").count, SearchQueryBuilder.maxTerms)
        XCTAssertTrue(expression?.contains("\"term31\"*") == true)
        XCTAssertTrue(expression?.contains("\"term32\"*") == false)
    }
}
