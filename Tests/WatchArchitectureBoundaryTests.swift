import Testing
@testable import TonearmWatchProtocol

@Suite struct WatchArchitectureBoundaryTests {
    @Test func testProtocolIdentityAndPlaybackTargetAreStable() {
        let id: WatchTrackID = "track-stable-id"
        #expect(id.rawValue == "track-stable-id")
        #expect(WatchProtocolVersion.current == 3, "Compressed selected catalogs require protocol v3 on both devices")
        #expect(WatchPlaybackTarget.iPhone.userFacingName == "iPhone")
        #expect(WatchPlaybackTarget.watch.userFacingName == "Apple Watch")
    }
}
