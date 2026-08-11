import XCTest

@testable import TonearmDJ

final class RoBERTaTokenizerTests: XCTestCase {

    private func tokenizer() throws -> RoBERTaTokenizer {
        try RoBERTaTokenizer(vocabURL: DJFixtures.url("vocab", ext: "json"),
                             mergesURL: DJFixtures.url("merges", ext: "txt"))
    }

    private func loadGolden() throws -> [String: [String: [[Int]]]] {
        let data = try Data(contentsOf: DJFixtures.url("text_tokenizer_golden", ext: "json"))
        return try JSONDecoder().decode([String: [String: [[Int]]]].self, from: data)
    }

    /// Byte-identical to `transformers.RobertaTokenizer` for the bundled tables.
    func testTokenizeMatchesReference() throws {
        let tokenizer = try tokenizer()
        let golden = try loadGolden()
        for (phrase, expected) in golden {
            // The reference tokenizer returns batch-shaped (1, 77) arrays.
            let ids = try XCTUnwrap(expected["ids"]?.first)
            let mask = try XCTUnwrap(expected["mask"]?.first)
            let encoded = try tokenizer.encode(phrase, maxLength: 77)
            XCTAssertEqual(Array(encoded.ids), ids, "ids mismatch for \(phrase)")
            XCTAssertEqual(Array(encoded.mask), mask, "mask mismatch for \(phrase)")
        }
    }

    func testPadsToMaxLength() throws {
        let tokenizer = try tokenizer()
        let encoded = try tokenizer.encode("kick", maxLength: 77)
        XCTAssertEqual(encoded.ids.count, 77)
        XCTAssertEqual(encoded.mask.count, 77)
        // <s> kick </s> <pad>...
        XCTAssertEqual(encoded.ids.first, RoBERTaTokenizer.bosID)
        XCTAssertEqual(Array(encoded.ids.prefix(3)), [0, 13_643, 2])  // "kick" (reference id)
        XCTAssertTrue(encoded.ids.suffix(74).allSatisfy { $0 == RoBERTaTokenizer.padID })
        XCTAssertEqual(encoded.mask.suffix(74).reduce(0, +), 0)
        XCTAssertEqual(Array(encoded.mask.prefix(3)), [1, 1, 1])
    }

    func testUnknownAndSpecialTokens() throws {
        let tokenizer = try tokenizer()
        // Empty input -> <s> </s> only.
        let empty = try tokenizer.encode("", maxLength: 77)
        XCTAssertEqual(Array(empty.ids.prefix(2)), [0, 2])
        // A long input truncates to fit: exactly one </s> and only <pad> after it.
        let long = String(repeating: "deep atmospheric techno ", count: 40)
        let encoded = try tokenizer.encode(long, maxLength: 77)
        XCTAssertEqual(encoded.ids.count, 77)
        XCTAssertEqual(encoded.ids.first, RoBERTaTokenizer.bosID)
        let eosIndex = try XCTUnwrap(encoded.ids.firstIndex(of: RoBERTaTokenizer.eosID))
        XCTAssertTrue(encoded.ids[(eosIndex + 1)...].allSatisfy { $0 == RoBERTaTokenizer.padID })
        XCTAssertEqual(encoded.mask[eosIndex], 1)
        XCTAssertEqual(encoded.mask[(eosIndex + 1)...].reduce(0, +), 0)
    }
}
