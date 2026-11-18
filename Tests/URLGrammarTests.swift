import Foundation
import Testing
@testable import TonearmCore

@Suite struct URLGrammarTests {

    @Test func testItemBare() {
        #expect(try? URLGrammar.parse("https://archive.org/details/GratefulDead1977").get() ==
                       .item(identifier: "GratefulDead1977", filename: nil))
    }

    @Test func testItemWithFilename() {
        #expect(try? URLGrammar.parse("archive.org/details/foo/track01.flac").get() ==
                       .item(identifier: "foo", filename: "track01.flac"))
    }

    @Test func testItemNestedFilename() {
        #expect(try? URLGrammar.parse("archive.org/details/foo/disc1/track01.flac").get() ==
                       .item(identifier: "foo", filename: "disc1/track01.flac"))
    }

    @Test func testList() {
        #expect(try? URLGrammar.parse("https://archive.org/details/@shellac_hound/lists/2841/early-opera").get() ==
                       .list(screenname: "shellac_hound", listId: "2841", slug: "early-opera"))
    }

    @Test func testListNoSlug() {
        #expect(try? URLGrammar.parse("archive.org/details/@user/lists/99").get() ==
                       .list(screenname: "user", listId: "99", slug: nil))
    }

    @Test func testListWithEncodedAtSign() {
        #expect(try? URLGrammar.parse("https://archive.org/details/%40user/lists/99/favorites").get() ==
                       .list(screenname: "user", listId: "99", slug: "favorites"))
    }

    @Test func testListsTab() {
        #expect(try? URLGrammar.parse("https://archive.org/details/@user/lists").get() ==
                       .lists(screenname: "user"))
    }

    @Test func testFavorites() {
        #expect(try? URLGrammar.parse("archive.org/details/fav-jsmith").get() ==
                       .favorites(screenname: "jsmith"))
    }

    @Test func testEmbedNormalizesToItem() {
        #expect(try? URLGrammar.parse("https://archive.org/embed/foo?start=10").get() ==
                       .item(identifier: "foo", filename: nil))
    }

    @Test func testTrailingQueryTolerated() {
        #expect(try? URLGrammar.parse("https://archive.org/details/foo?utm=x&y=1").get() ==
                       .item(identifier: "foo", filename: nil))
    }

    @Test func testWwwHostAccepted() {
        #expect(try? URLGrammar.parse("https://www.archive.org/details/foo").get() ==
                       .item(identifier: "foo", filename: nil))
    }

    // MARK: - Share-sheet payloads

    @Test func testShareSheetURLPayloadExtractsArchiveURL() throws {
        let raw = "https://archive.org/details/foo"
        let resolved = SharePayloadResolver.archiveURL(from: [
            .url(try #require(URL(string: raw)))
        ])

        #expect(resolved == raw)
    }

    @Test func testShareSheetTextPayloadExtractsArchiveURL() {
        let resolved = SharePayloadResolver.archiveURL(from: [
            .text("Listen here: https://archive.org/details/foo/track01.flac")
        ])

        #expect(resolved == "https://archive.org/details/foo/track01.flac")
    }

    @Test func testShareSheetAttributedPayloadExtractsArchiveURL() {
        let resolved = SharePayloadResolver.archiveURL(from: [
            .attributedText("Archive source\narchive.org/details/@user/lists/99")
        ])

        #expect(resolved == "archive.org/details/@user/lists/99")
    }

    @Test func testShareSheetPayloadSkipsForeignURLs() throws {
        let resolved = SharePayloadResolver.archiveURL(from: [
            .url(try #require(URL(string: "https://example.com/details/nope"))),
            .text("fallback https://archive.org/details/good")
        ])

        #expect(resolved == "https://archive.org/details/good")
    }

    @Test func testTonearmDeepLinkRoundTripForSharedURL() throws {
        let raw = "https://archive.org/details/foo?utm=x"
        let url = try #require(TonearmDeepLink.url(for: .addSource(raw)))

        #expect(TonearmDeepLink.parse(url) == .addSource(raw))
    }

    @Test func testTonearmDeepLinkRoundTripsWidgetControls() throws {
        let actions: [TonearmDeepLink] = [
            .nowPlaying,
            .resumePlayback,
            .pausePlayback,
            .togglePlayback,
            .nextTrack,
            .previousTrack
        ]

        for action in actions {
            let url = try #require(TonearmDeepLink.url(for: action))
            #expect(TonearmDeepLink.parse(url) == action)
        }
    }

    // MARK: - Rejections

    @Test func testEmpty() {
        assertFails("", .empty)
        assertFails("   ", .empty)
    }

    @Test func testWayback() {
        assertFails("https://web.archive.org/web/2020/http://x.com", .wayback)
    }

    @Test func testForeignHost() {
        assertFails("https://example.com/details/foo", .notArchiveHost)
        assertFails("https://archive.org.evil.com/details/foo", .notArchiveHost)
    }

    @Test func testUnrecognizedPaths() {
        assertFails("https://archive.org/", .unrecognized)
        assertFails("https://archive.org/search?query=bach", .unrecognized)
        assertFails("https://archive.org/details/", .unrecognized)
        assertFails("https://archive.org/details/@user", .unrecognized)
        assertFails("https://archive.org/details/@/lists/1", .unrecognized)
        assertFails("https://archive.org/details/fav-", .unrecognized)
        assertFails("https://archive.org/advancedsearch.php", .unrecognized)
        assertFails("https://archive.org/embed/", .unrecognized)
        assertFails("https://archive.org/about", .unrecognized)
    }

    private func assertFails(_ input: String, _ expected: IAURLError,
                             sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        switch URLGrammar.parse(input) {
        case .success(let v):
            Issue.record("Expected failure but got \(v)", sourceLocation: sourceLocation)
        case .failure(let e):
            #expect(e == expected, sourceLocation: sourceLocation)
        }
    }
}
