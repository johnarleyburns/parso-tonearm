import XCTest
@testable import TonearmWatchCore

final class WatchArtworkResolverTests: XCTestCase {
    func testResolutionPrecedenceAndUnavailableFallbacks() {
        let cases: [(String?, String?, Set<String>, WatchArtworkSource, String?)] = [
            ("custom", "cover", ["custom", "cover"], .custom, "custom"),
            ("custom", "cover", ["cover"], .cover, "cover"),
            (nil, "cover", ["cover"], .cover, "cover"),
            ("missing", "also-missing", [], .none, nil),
            (nil, nil, [], .none, nil)
        ]

        for (custom, cover, installedIDs, expectedSource, expectedID) in cases {
            let result = WatchArtworkResolver.resolve(
                customArtworkID: custom, coverArtworkID: cover,
                installed: installedIDs.contains)
            XCTAssertEqual(result.0, expectedSource)
            XCTAssertEqual(result.artworkID, expectedID)
        }
    }
}
