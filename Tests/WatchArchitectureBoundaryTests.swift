import XCTest
@testable import TonearmWatchProtocol

final class WatchArchitectureBoundaryTests: XCTestCase {
    func testProtocolIdentityAndPlaybackTargetAreStable() {
        let id: WatchTrackID = "track-stable-id"
        XCTAssertEqual(id.rawValue, "track-stable-id")
        XCTAssertEqual(WatchProtocolVersion.current, 2, "Resumable chunk transfers require protocol v2")
        XCTAssertEqual(WatchPlaybackTarget.iPhone.userFacingName, "iPhone")
        XCTAssertEqual(WatchPlaybackTarget.watch.userFacingName, "Apple Watch")
    }
}
