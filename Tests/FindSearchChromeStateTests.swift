import XCTest

@testable import TonearmCore

final class FindSearchChromeStateTests: XCTestCase {
    private func state(find: Bool = true, focused: Bool, track: Bool = true,
                       nowPlaying: Bool = false) -> FindSearchChromeState {
        .init(isFindActive: find, isQueryFocused: focused, hasCurrentTrack: track,
              isNowPlayingPresented: nowPlaying)
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

    func testLeavingFocusRestoresOrdinaryHeights() {
        XCTAssertEqual(state(focused: false).accessoryHeight, 56)
        XCTAssertEqual(state(focused: false, track: false).accessoryHeight, 0)
    }

    func testNowPlayingClearsEditingAndAccessory() {
        let s = state(focused: true, nowPlaying: true)
        XCTAssertFalse(s.hidesNavigationChrome)
        XCTAssertEqual(s.accessoryHeight, 0)
    }
}

final class RootViewAccessoryStructureTests: XCTestCase {
    private func rootViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Features/RootView.swift"), encoding: .utf8)
    }

    func testMiniPlayerUsesSystemTabViewBottomAccessory() throws {
        let src = try rootViewSource()
        XCTAssertTrue(src.contains(".tabViewBottomAccessory"))
        XCTAssertFalse(src.contains(".zIndex("), "manual ZStack/zIndex accessory composition is forbidden")
        XCTAssertFalse(src.contains(".padding(.bottom, 58)"))
        XCTAssertNil(src.range(of: #"\.padding\(\.bottom,\s*\d+\)"#, options: .regularExpression),
                     "no hardcoded bottom padding for the accessory")
    }

    func testNoDuplicatedAccessoryPaddingLiteral() {
        XCTAssertEqual(FindSearchChromeState(isFindActive: false, isQueryFocused: false, hasCurrentTrack: true,
                                             isNowPlayingPresented: false).accessoryHeight,
                       FindSearchChromeState.trackAccessoryHeight)
    }

    /// Real report: the system `.tabViewBottomAccessory` renders a single-row-tall accessory —
    /// when the watch-transfer banner and the mini player both tried to occupy it at once, the
    /// user saw a composite of the bottom half of one bar and the top half of the other. Watch
    /// transfer status must never be shown in this surface again; My Music's "On My Watch"
    /// section owns it instead.
    func testMiniPlayerAccessoryNeverShowsWatchTransferStatus() throws {
        let src = try rootViewSource()
        XCTAssertFalse(src.contains("TransferPill"), "the root tab accessory must never show watch transfer status")
    }

    /// The standalone Mood tab was folded into Find's own Mood mode (pills + songs-only).
    func testStandaloneMoodTabIsRemoved() throws {
        let src = try rootViewSource()
        XCTAssertFalse(src.contains("MoodView()"))
        XCTAssertFalse(src.contains("AppTab.mood"))
    }
}
