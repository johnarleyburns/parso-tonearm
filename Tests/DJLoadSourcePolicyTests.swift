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
}
