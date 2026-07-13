import XCTest
@testable import Tonearm

final class URLGrammarTests: XCTestCase {

    func testItemBare() {
        XCTAssertEqual(try? URLGrammar.parse("https://archive.org/details/GratefulDead1977").get(),
                       .item(identifier: "GratefulDead1977", filename: nil))
    }

    func testItemWithFilename() {
        XCTAssertEqual(try? URLGrammar.parse("archive.org/details/foo/track01.flac").get(),
                       .item(identifier: "foo", filename: "track01.flac"))
    }

    func testItemNestedFilename() {
        XCTAssertEqual(try? URLGrammar.parse("archive.org/details/foo/disc1/track01.flac").get(),
                       .item(identifier: "foo", filename: "disc1/track01.flac"))
    }

    func testList() {
        XCTAssertEqual(try? URLGrammar.parse("https://archive.org/details/@shellac_hound/lists/2841/early-opera").get(),
                       .list(screenname: "shellac_hound", listId: "2841", slug: "early-opera"))
    }

    func testListNoSlug() {
        XCTAssertEqual(try? URLGrammar.parse("archive.org/details/@user/lists/99").get(),
                       .list(screenname: "user", listId: "99", slug: nil))
    }

    func testFavorites() {
        XCTAssertEqual(try? URLGrammar.parse("archive.org/details/fav-jsmith").get(),
                       .favorites(screenname: "jsmith"))
    }

    func testEmbedNormalizesToItem() {
        XCTAssertEqual(try? URLGrammar.parse("https://archive.org/embed/foo?start=10").get(),
                       .item(identifier: "foo", filename: nil))
    }

    func testTrailingQueryTolerated() {
        XCTAssertEqual(try? URLGrammar.parse("https://archive.org/details/foo?utm=x&y=1").get(),
                       .item(identifier: "foo", filename: nil))
    }

    func testWwwHostAccepted() {
        XCTAssertEqual(try? URLGrammar.parse("https://www.archive.org/details/foo").get(),
                       .item(identifier: "foo", filename: nil))
    }

    // MARK: - Share-sheet payloads

    func testShareSheetURLPayloadExtractsArchiveURL() throws {
        let raw = "https://archive.org/details/foo"
        let resolved = SharePayloadResolver.archiveURL(from: [
            .url(try XCTUnwrap(URL(string: raw)))
        ])

        XCTAssertEqual(resolved, raw)
    }

    func testShareSheetTextPayloadExtractsArchiveURL() {
        let resolved = SharePayloadResolver.archiveURL(from: [
            .text("Listen here: https://archive.org/details/foo/track01.flac")
        ])

        XCTAssertEqual(resolved, "https://archive.org/details/foo/track01.flac")
    }

    func testShareSheetAttributedPayloadExtractsArchiveURL() {
        let resolved = SharePayloadResolver.archiveURL(from: [
            .attributedText("Archive source\narchive.org/details/@user/lists/99")
        ])

        XCTAssertEqual(resolved, "archive.org/details/@user/lists/99")
    }

    func testShareSheetPayloadSkipsForeignURLs() throws {
        let resolved = SharePayloadResolver.archiveURL(from: [
            .url(try XCTUnwrap(URL(string: "https://example.com/details/nope"))),
            .text("fallback https://archive.org/details/good")
        ])

        XCTAssertEqual(resolved, "https://archive.org/details/good")
    }

    func testTonearmDeepLinkRoundTripForSharedURL() throws {
        let raw = "https://archive.org/details/foo?utm=x"
        let url = try XCTUnwrap(TonearmDeepLink.url(for: .addSource(raw)))

        XCTAssertEqual(TonearmDeepLink.parse(url), .addSource(raw))
    }

    func testTonearmDeepLinkRoundTripsWidgetControls() throws {
        let actions: [TonearmDeepLink] = [
            .nowPlaying,
            .resumePlayback,
            .pausePlayback,
            .togglePlayback,
            .nextTrack,
            .previousTrack
        ]

        for action in actions {
            let url = try XCTUnwrap(TonearmDeepLink.url(for: action))
            XCTAssertEqual(TonearmDeepLink.parse(url), action)
        }
    }

    // MARK: - Rejections

    func testEmpty() {
        assertFails("", .empty)
        assertFails("   ", .empty)
    }

    func testWayback() {
        assertFails("https://web.archive.org/web/2020/http://x.com", .wayback)
    }

    func testForeignHost() {
        assertFails("https://example.com/details/foo", .notArchiveHost)
        assertFails("https://archive.org.evil.com/details/foo", .notArchiveHost)
    }

    func testUnrecognizedPaths() {
        assertFails("https://archive.org/", .unrecognized)
        assertFails("https://archive.org/search?query=bach", .unrecognized)
        assertFails("https://archive.org/details/", .unrecognized)
        assertFails("https://archive.org/details/@user", .unrecognized)
        assertFails("https://archive.org/details/@user/lists", .unrecognized)
        assertFails("https://archive.org/details/@/lists/1", .unrecognized)
        assertFails("https://archive.org/details/fav-", .unrecognized)
        assertFails("https://archive.org/advancedsearch.php", .unrecognized)
        assertFails("https://archive.org/embed/", .unrecognized)
        assertFails("https://archive.org/about", .unrecognized)
    }

    private func assertFails(_ input: String, _ expected: IAURLError,
                             file: StaticString = #filePath, line: UInt = #line) {
        switch URLGrammar.parse(input) {
        case .success(let v):
            XCTFail("Expected failure but got \(v)", file: file, line: line)
        case .failure(let e):
            XCTAssertEqual(e, expected, file: file, line: line)
        }
    }
}
