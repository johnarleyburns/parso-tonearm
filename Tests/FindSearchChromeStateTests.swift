import Foundation
import Testing

@testable import TonearmCore

@Suite struct FindSearchChromeStateTests {
    private func state(find: Bool = true, focused: Bool, track: Bool = true,
                       nowPlaying: Bool = false) -> FindSearchChromeState {
        .init(isFindActive: find, isQueryFocused: focused, hasCurrentTrack: track,
              isNowPlayingPresented: nowPlaying)
    }

    @Test func testFocusedFindHidesEverything() {
        let s = state(focused: true)
        #expect(s.hidesNavigationChrome)
        #expect(!s.showsMiniPlayer)
        #expect(s.accessoryHeight == 0)
    }

    @Test func testUnfocusedFindKeepsStandardChrome() {
        let s = state(focused: false)
        #expect(!s.hidesNavigationChrome)
        #expect(s.showsMiniPlayer)
        #expect(s.accessoryHeight > 0)
    }

    @Test func testStaleFocusOnOtherTabKeepsMiniPlayer() {
        let s = state(find: false, focused: true)
        #expect(!s.hidesNavigationChrome)
        #expect(s.showsMiniPlayer)
        #expect(s.accessoryHeight == state(find: false, focused: false).accessoryHeight)
    }

    @Test func testFocusedWithoutTrackHidesChromeWithZeroHeight() {
        let s = state(focused: true, track: false)
        #expect(s.hidesNavigationChrome)
        #expect(s.accessoryHeight == 0)
    }

    @Test func testLeavingFocusRestoresOrdinaryHeights() {
        #expect(state(focused: false).accessoryHeight == 56)
        #expect(state(focused: false, track: false).accessoryHeight == 0)
    }

    @Test func testNowPlayingClearsEditingAndAccessory() {
        let s = state(focused: true, nowPlaying: true)
        #expect(!s.hidesNavigationChrome)
        #expect(s.accessoryHeight == 0)
    }
}

@Suite struct RootViewAccessoryStructureTests {
    private func rootViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Features/RootView.swift"), encoding: .utf8)
    }

    @Test func testMiniPlayerUsesSystemTabViewBottomAccessory() throws {
        let src = try rootViewSource()
        #expect(src.contains(".tabViewBottomAccessory"))
        #expect(!src.contains(".zIndex("), "manual ZStack/zIndex accessory composition is forbidden")
        #expect(!src.contains(".padding(.bottom, 58)"))
        #expect(src.range(of: #"\.padding\(\.bottom,\s*\d+\)"#, options: .regularExpression) == nil,
                     "no hardcoded bottom padding for the accessory")
    }

    @Test func testNoDuplicatedAccessoryPaddingLiteral() {
        #expect(FindSearchChromeState(isFindActive: false, isQueryFocused: false, hasCurrentTrack: true,
                                             isNowPlayingPresented: false).accessoryHeight ==
                       FindSearchChromeState.trackAccessoryHeight)
    }

    /// Real report: the system `.tabViewBottomAccessory` renders a single-row-tall accessory —
    /// when the watch-transfer banner and the mini player both tried to occupy it at once, the
    /// user saw a composite of the bottom half of one bar and the top half of the other. Watch
    /// transfer status must never be shown in this surface again; My Music's "On My Watch"
    /// section owns it instead.
    @Test func testMiniPlayerAccessoryNeverShowsWatchTransferStatus() throws {
        let src = try rootViewSource()
        #expect(!src.contains("TransferPill"), "the root tab accessory must never show watch transfer status")
    }

    /// The standalone Mood tab was folded into Find's own Mood mode (pills + songs-only).
    @Test func testStandaloneMoodTabIsRemoved() throws {
        let src = try rootViewSource()
        #expect(!src.contains("MoodView()"))
        #expect(!src.contains("AppTab.mood"))
    }
}
