import XCTest
@testable import TonearmCore

final class DJLoadSourcePolicyTests: XCTestCase {
    func testStaleBookmarkDoesNotOverrideVerifiedFallbackURL() {
        let stale = URL(fileURLWithPath: "/Music/old/song.mp3")
        let verified = URL(fileURLWithPath: "/Library/Caches/Tonearm/song.mp3")

        XCTAssertFalse(
            DJLoadSourcePolicy.shouldUseBookmark(bookmarkURL: stale, sourceURL: verified))
    }

    func testMatchingBookmarkKeepsSecurityScopedPreparationPath() {
        let file = URL(fileURLWithPath: "/Music/song.mp3")

        XCTAssertTrue(
            DJLoadSourcePolicy.shouldUseBookmark(bookmarkURL: file, sourceURL: file))
    }

    func testExtensionlessRemoteCacheUsesOriginalFormatQuery() {
        let cached = URL(fileURLWithPath: "/Caches/audio/abc123")
        let original = URL(string: "https://cdn.example.test/stream?format=mp32")

        XCTAssertEqual(
            DJLoadSourcePolicy.containerHint(codec: nil, sourceURL: cached, originalURL: original),
            "mp3")
    }

    func testCodecHintWinsWhenTheCacheBlobHasNoExtension() {
        let cached = URL(fileURLWithPath: "/Caches/audio/abc123")

        XCTAssertEqual(
            DJLoadSourcePolicy.containerHint(codec: "audio/flac", sourceURL: cached),
            "flac")
    }

    func testFailurePresentationRetainsStageAndUnderlyingError() {
        let message = DJLoadFailurePresentation.message(
            stage: .decodeAndAnalyze,
            error: NSError(domain: "Audio", code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "invalid MP3 frame"]),
            trackTitle: "Test track",
            sourceURL: URL(fileURLWithPath: "/Caches/audio/blob"),
            codec: nil)

        XCTAssertTrue(message.contains("decode/analyze"))
        XCTAssertTrue(message.contains("invalid MP3 frame"))
        XCTAssertTrue(message.contains("Codec hint: unknown"))
    }
}
