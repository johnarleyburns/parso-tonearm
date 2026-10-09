import XCTest
@testable import TonearmWatchProtocol

final class WatchArchitectureBoundaryTests: XCTestCase {
    func testProtocolIdentityAndPlaybackTargetAreStable() {
        let id: WatchTrackID = "track-stable-id"
        XCTAssertEqual(id.rawValue, "track-stable-id")
        XCTAssertEqual(WatchProtocolVersion.current, 3, "Compressed selected catalogs require protocol v3 on both devices")
        XCTAssertEqual(WatchPlaybackTarget.iPhone.userFacingName, "iPhone")
        XCTAssertEqual(WatchPlaybackTarget.watch.userFacingName, "Apple Watch")
    }
}
