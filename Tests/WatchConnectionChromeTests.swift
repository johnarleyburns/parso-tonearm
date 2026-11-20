import Testing
@testable import TonearmWatchCore
import TonearmWatchProtocol

@MainActor
@Suite struct WatchConnectionChromeTests {
    @Test func testBlipShowsTransientBannerButKeepsConnectedFeatures() {
        let chrome = WatchConnectionChrome(initial: .connected)
        chrome.apply(connectivity: .temporarilyUnavailable)
        #expect(chrome.banner == .temporarilyUnavailable)
        // C-08: a blip shows a transient hint but is not a confirmed offline banner.
        #expect(!chrome.showsOfflineBanner)
    }

    @Test func testColdStartIsOfflineUntilNegotiated() {
        let chrome = WatchConnectionChrome()
        #expect(chrome.banner == .unavailable)
        #expect(!chrome.showsConnectedFeatures)
        chrome.apply(connectivity: .connected)
        #expect(chrome.showsConnectedFeatures)
    }

    @Test func testConfirmedDisconnectionPulsesOnceAndShowsOfflineBanner() {
        let chrome = WatchConnectionChrome()
        chrome.confirmedDisconnection()
        chrome.confirmedDisconnection()
        #expect(chrome.banner == .unavailable)
        #expect(chrome.showsOfflineBanner)
        #expect(chrome.disconnectPulse == 2)
    }

    @Test func testReconnectRestoresConnectedUnlessIncompatible() {
        let chrome = WatchConnectionChrome()
        chrome.confirmedDisconnection()
        chrome.reconnected()
        #expect(chrome.banner == .connected)
        #expect(chrome.showsConnectedFeatures)

        chrome.markIncompatible()
        chrome.apply(connectivity: .connected)
        chrome.reconnected()
        #expect(chrome.banner == .incompatible, "incompatibility is sticky until relaunch")
    }

    @Test func testLibraryReplacementPrompt() {
        let chrome = WatchConnectionChrome()
        #expect(chrome.pendingLibraryReplacement == nil)
        chrome.requestLibraryReplacement(current: "lib-a", incoming: "lib-b")
        #expect(chrome.pendingLibraryReplacement == "lib-b")
        chrome.resolveLibraryReplacement()
        #expect(chrome.pendingLibraryReplacement == nil)
    }
}
