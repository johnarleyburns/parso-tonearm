import XCTest

@testable import TonearmCore

final class FindSearchChromeStateTests: XCTestCase {
    private func state(find: Bool = true, focused: Bool, track: Bool = true,
                       banner: Bool = false, nowPlaying: Bool = false) -> FindSearchChromeState {
        .init(isFindActive: find, isQueryFocused: focused, hasCurrentTrack: track,
              hasTransferBanner: banner, isNowPlayingPresented: nowPlaying)
    }

    func testFocusedFindHidesEverything() {
        let s = state(focused: true)
        XCTAssertTrue(s.hidesNavigationChrome)
        XCTAssertFalse(s.showsMiniPlayer)
        XCTAssertEqual(s.accessoryHeight, 0)
    }

    func testUnfocusedFindKeepsStandardChrome() {
        let s = state(focused: false)
        XCTAssertFalse(s.hidesNavigationChrome)
        XCTAssertTrue(s.showsMiniPlayer)
        XCTAssertGreaterThan(s.accessoryHeight, 0)
    }

    func testStaleFocusOnOtherTabKeepsMiniPlayer() {
        let s = state(find: false, focused: true)
        XCTAssertFalse(s.hidesNavigationChrome)
        XCTAssertTrue(s.showsMiniPlayer)
        XCTAssertEqual(s.accessoryHeight, state(find: false, focused: false).accessoryHeight)
    }

    func testFocusedWithoutTrackHidesChromeWithZeroHeight() {
        let s = state(focused: true, track: false)
        XCTAssertTrue(s.hidesNavigationChrome)
        XCTAssertEqual(s.accessoryHeight, 0)
    }

    func testFocusedWithTransferBannerPaintsNothing() {
        let s = state(focused: true, banner: true)
        XCTAssertFalse(s.showsTransferBanner)
        XCTAssertEqual(s.accessoryHeight, 0)
    }

    func testLeavingFocusRestoresOrdinaryHeights() {
        XCTAssertEqual(state(focused: false, banner: true).accessoryHeight, 56 * 2 + 4 + 58)
        XCTAssertEqual(state(focused: false).accessoryHeight, 56 + 58)
        XCTAssertEqual(state(focused: false, track: false).accessoryHeight, 0)
    }

    func testNowPlayingClearsEditingAndAccessory() {
        let s = state(focused: true, nowPlaying: true)
        XCTAssertFalse(s.hidesNavigationChrome)
        XCTAssertEqual(s.accessoryHeight, 0)
    }
}
