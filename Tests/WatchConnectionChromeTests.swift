import XCTest
@testable import TonearmWatchCore
import TonearmWatchProtocol

@MainActor
final class WatchConnectionChromeTests: XCTestCase {
    func testBlipShowsTransientBannerButKeepsConnectedFeatures() {
        let chrome = WatchConnectionChrome(initial: .connected)
        chrome.apply(connectivity: .temporarilyUnavailable)
        XCTAssertEqual(chrome.banner, .temporarilyUnavailable)
        // C-08: a blip shows a transient hint but is not a confirmed offline banner.
        XCTAssertFalse(chrome.showsOfflineBanner)
    }

    func testColdStartIsOfflineUntilNegotiated() {
        let chrome = WatchConnectionChrome()
        XCTAssertEqual(chrome.banner, .unavailable)
        XCTAssertFalse(chrome.showsConnectedFeatures)
        chrome.apply(connectivity: .connected)
        XCTAssertTrue(chrome.showsConnectedFeatures)
    }

    func testConfirmedDisconnectionPulsesOnceAndShowsOfflineBanner() {
        let chrome = WatchConnectionChrome()
        chrome.confirmedDisconnection()
        chrome.confirmedDisconnection()
        XCTAssertEqual(chrome.banner, .unavailable)
        XCTAssertTrue(chrome.showsOfflineBanner)
        XCTAssertEqual(chrome.disconnectPulse, 2)
    }

    func testReconnectRestoresConnectedUnlessIncompatible() {
        let chrome = WatchConnectionChrome()
        chrome.confirmedDisconnection()
        chrome.reconnected()
        XCTAssertEqual(chrome.banner, .connected)
        XCTAssertTrue(chrome.showsConnectedFeatures)

        chrome.markIncompatible()
        chrome.apply(connectivity: .connected)
        chrome.reconnected()
        XCTAssertEqual(chrome.banner, .incompatible, "incompatibility is sticky until relaunch")
    }

    func testLibraryReplacementPrompt() {
        let chrome = WatchConnectionChrome()
        XCTAssertNil(chrome.pendingLibraryReplacement)
        chrome.requestLibraryReplacement(current: "lib-a", incoming: "lib-b")
        XCTAssertEqual(chrome.pendingLibraryReplacement, "lib-b")
        chrome.resolveLibraryReplacement()
        XCTAssertNil(chrome.pendingLibraryReplacement)
    }
}
