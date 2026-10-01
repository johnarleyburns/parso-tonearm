import XCTest
@testable import TonearmWatchCore

/// Phase 9c — the explicit playback target and its persistence (§7.1: "defaults to the last
/// explicit target, initially iPhone").
final class WatchPlaybackTargetTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "WatchPlaybackTargetTests-\(UUID().uuidString)")!
        return d
    }

    func testDefaultsToIPhoneWhenNothingStored() {
        XCTAssertEqual(WatchPlaybackTargetStore.load(defaults: makeDefaults()), .iPhone)
    }

    func testRoundTrips() {
        let d = makeDefaults()
        WatchPlaybackTargetStore.save(.thisWatch, defaults: d)
        XCTAssertEqual(WatchPlaybackTargetStore.load(defaults: d), .thisWatch)
        WatchPlaybackTargetStore.save(.iPhone, defaults: d)
        XCTAssertEqual(WatchPlaybackTargetStore.load(defaults: d), .iPhone)
    }

    func testUnrecognisedStoredValueFallsBackToIPhone() {
        let d = makeDefaults()
        d.set("appleTV", forKey: "guru.parso.tonearm.watch.playback.target")
        XCTAssertEqual(WatchPlaybackTargetStore.load(defaults: d), .iPhone)
    }

    func testClearResetsToDefault() {
        let d = makeDefaults()
        WatchPlaybackTargetStore.save(.thisWatch, defaults: d)
        WatchPlaybackTargetStore.clear(defaults: d)
        XCTAssertEqual(WatchPlaybackTargetStore.load(defaults: d), .iPhone)
    }

    func testOtherIsTheOppositeTarget() {
        XCTAssertEqual(WatchPlaybackTarget.iPhone.other, .thisWatch)
        XCTAssertEqual(WatchPlaybackTarget.thisWatch.other, .iPhone)
    }
}

/// Watch redesign §4 / T2 — the hero follows playback on either device without switching targets.
final class WatchNowPlayingResolverTests: XCTestCase {
    private typealias E = WatchNowPlayingResolver.Engine

    func testPhoneStartedPlaybackShowsEvenWhenTargetIsTheWatch() {
        let shown = WatchNowPlayingResolver.shown(
            local: E(hasItem: true, isPlaying: false), remote: E(hasItem: true, isPlaying: true),
            target: .thisWatch)
        XCTAssertEqual(shown, .iPhone, "music started on the iPhone must reach the hero")
    }

    func testLocalAudioWinsWhenBothPlay() {
        XCTAssertEqual(WatchNowPlayingResolver.shown(
            local: E(hasItem: true, isPlaying: true), remote: E(hasItem: true, isPlaying: true),
            target: .iPhone), .thisWatch)
    }

    func testPausedEnginesPreferTheExplicitTarget() {
        let paused = E(hasItem: true, isPlaying: false)
        XCTAssertEqual(WatchNowPlayingResolver.shown(local: paused, remote: paused, target: .iPhone), .iPhone)
        XCTAssertEqual(WatchNowPlayingResolver.shown(local: paused, remote: paused, target: .thisWatch), .thisWatch)
    }

    func testFallsBackToWhicheverEngineHasAnItem() {
        XCTAssertEqual(WatchNowPlayingResolver.shown(
            local: .empty, remote: E(hasItem: true, isPlaying: false), target: .thisWatch), .iPhone)
        XCTAssertNil(WatchNowPlayingResolver.shown(local: .empty, remote: .empty, target: .iPhone))
    }

    func testStoredPreferenceIsDetected() {
        let defaults = UserDefaults(suiteName: "resolver-\(UUID().uuidString)")!
        XCTAssertFalse(WatchPlaybackTargetStore.hasStoredPreference(defaults: defaults))
        WatchPlaybackTargetStore.save(.thisWatch, defaults: defaults)
        XCTAssertTrue(WatchPlaybackTargetStore.hasStoredPreference(defaults: defaults))
    }
}

/// Watch redesign §6.4 — reachability, search scope and the banner come from one source.
@MainActor
final class WatchConnectionProjectionTests: XCTestCase {
    func testEveryBannerYieldsAgreeingReachabilityAndScope() {
        let cases: [(WatchConnectionChrome.Banner, Bool)] = [
            (.connected, true), (.temporarilyUnavailable, false), (.unavailable, false), (.incompatible, false)
        ]
        for (banner, reachable) in cases {
            let projection = WatchConnectionProjection(banner: banner)
            XCTAssertEqual(projection.phoneReachable, reachable, "\(banner)")
            XCTAssertEqual(projection.searchMode, reachable ? .connected : .offline, "\(banner)")
        }
    }

    func testNegotiationThenReconnectLeavesChromeConnected() {
        let chrome = WatchConnectionChrome()
        XCTAssertFalse(WatchConnectionProjection(banner: chrome.banner).phoneReachable)
        chrome.reconnected()  // what `didNegotiate` does
        XCTAssertTrue(WatchConnectionProjection(banner: chrome.banner).phoneReachable,
                      "a negotiated session must mark the phone reachable everywhere at once")
        chrome.apply(connectivity: .temporarilyUnavailable)
        XCTAssertFalse(WatchConnectionProjection(banner: chrome.banner).phoneReachable)
    }
}

/// Watch redesign A2 — the Smart Stack widget state round-trips and reloads only on real changes.
final class WatchNowPlayingWidgetStateTests: XCTestCase {
    func testRoundTripAndStructuralChange() {
        let defaults = UserDefaults(suiteName: "widget-\(UUID().uuidString)")!
        let anchor = Date(timeIntervalSince1970: 1_000)
        let state = WatchNowPlayingWidgetState(title: "Teardrop", subtitle: "Massive Attack", target: .iPhone,
                                               isPlaying: true, elapsed: 60, duration: 300, anchorDate: anchor)
        WatchNowPlayingWidgetStore.save(state, defaults: defaults)
        XCTAssertEqual(WatchNowPlayingWidgetStore.load(defaults: defaults), state)
        XCTAssertEqual(state.startDate, Date(timeIntervalSince1970: 940))

        var ticked = state
        ticked.elapsed = 61
        ticked.anchorDate = anchor.addingTimeInterval(1)
        XCTAssertFalse(ticked.differsStructurally(from: state), "a clock tick must not reload the widget")
        ticked.isPlaying = false
        XCTAssertTrue(ticked.differsStructurally(from: state))

        WatchNowPlayingWidgetStore.save(nil, defaults: defaults)
        XCTAssertNil(WatchNowPlayingWidgetStore.load(defaults: defaults))
    }
}
