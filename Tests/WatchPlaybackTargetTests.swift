import Foundation
import Testing
@testable import TonearmWatchCore
import TonearmWatchProtocol

/// Watch redesign §6.4 — reachability, search scope and the banner come from one source.
@MainActor
@Suite struct WatchConnectionProjectionTests {
    @Test func testEveryBannerYieldsAgreeingReachabilityAndScope() {
        let cases: [(WatchConnectionChrome.Banner, Bool)] = [
            (.connected, true), (.temporarilyUnavailable, false), (.unavailable, false), (.incompatible, false)
        ]
        for (banner, reachable) in cases {
            let projection = WatchConnectionProjection(banner: banner)
            #expect(projection.phoneReachable == reachable, "\(banner)")
            #expect(projection.searchMode == (reachable ? .connected : .offline), "\(banner)")
        }
    }

    @Test func testNegotiationThenReconnectLeavesChromeConnected() {
        let chrome = WatchConnectionChrome()
        #expect(!WatchConnectionProjection(banner: chrome.banner).phoneReachable)
        chrome.reconnected()  // what `didNegotiate` does
        #expect(WatchConnectionProjection(banner: chrome.banner).phoneReachable,
                      "a negotiated session must mark the phone reachable everywhere at once")
        chrome.apply(connectivity: .temporarilyUnavailable)
        #expect(!WatchConnectionProjection(banner: chrome.banner).phoneReachable)
    }
}

/// Watch redesign A2 — the Smart Stack widget state round-trips and reloads only on real changes.
@Suite struct WatchNowPlayingWidgetStateTests {
    @Test func testRoundTripAndStructuralChange() {
        let defaults = InMemoryDefaultsStore()
        let anchor = Date(timeIntervalSince1970: 1_000)
        let state = WatchNowPlayingWidgetState(title: "Teardrop", subtitle: "Massive Attack", target: .iPhone,
                                               isPlaying: true, elapsed: 60, duration: 300, anchorDate: anchor)
        WatchNowPlayingWidgetStore.save(state, defaults: defaults)
        #expect(WatchNowPlayingWidgetStore.load(defaults: defaults) == state)
        #expect(state.startDate == Date(timeIntervalSince1970: 940))

        var ticked = state
        ticked.elapsed = 61
        ticked.anchorDate = anchor.addingTimeInterval(1)
        #expect(!ticked.differsStructurally(from: state), "a clock tick must not reload the widget")
        ticked.isPlaying = false
        #expect(ticked.differsStructurally(from: state))

        WatchNowPlayingWidgetStore.save(nil, defaults: defaults)
        #expect(WatchNowPlayingWidgetStore.load(defaults: defaults) == nil)
    }
}
