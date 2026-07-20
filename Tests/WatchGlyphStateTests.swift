import XCTest
@testable import TonearmCore

final class WatchGlyphStateTests: XCTestCase {

    func testNotOnWatchByDefault() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: [], transferState: nil, errorText: nil)
        XCTAssertEqual(state, .notOnWatch)
    }

    func testOnWatchWhenInManifest() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: ["t1", "t2"], transferState: nil, errorText: nil)
        XCTAssertEqual(state, .onWatch)
    }

    func testTransferringWhenQueued() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: [], transferState: .queued, errorText: nil)
        XCTAssertEqual(state, .transferring(progress: nil))
    }

    func testTransferringWhenSending() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: [], transferState: .sending, errorText: nil)
        XCTAssertEqual(state, .transferring(progress: nil))
    }

    func testOnWatchWhenSent() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: [], transferState: .sent, errorText: nil)
        XCTAssertEqual(state, .onWatch)
    }

    func testFailedWhenTransferFailed() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: [], transferState: .failed, errorText: "timeout")
        XCTAssertEqual(state, .failed)
    }

    func testFailedWithErrorTextOnly() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: [], transferState: nil, errorText: "some error")
        XCTAssertEqual(state, .failed)
    }

    func testTransferringOverridesOnWatch() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: ["t1"], transferState: .queued, errorText: nil)
        XCTAssertEqual(state, .transferring(progress: nil), "transferring should override manifest")
    }

    // MARK: - Aggregate state

    func testAggregateAllOnWatch() {
        let (state, fraction) = WatchGlyph.aggregateState(
            trackKeys: ["t1", "t2"],
            manifest: ["t1", "t2"],
            transferStates: [:],
            errorTexts: [:])
        XCTAssertEqual(state, .onWatch)
        XCTAssertEqual(fraction, 1.0)
    }

    func testAggregateNoneOnWatch() {
        let (state, fraction) = WatchGlyph.aggregateState(
            trackKeys: ["t1", "t2"],
            manifest: [],
            transferStates: [:],
            errorTexts: [:])
        XCTAssertEqual(state, .notOnWatch)
        XCTAssertEqual(fraction, 0.0)
    }

    func testAggregatePartialOnWatch() {
        let (state, fraction) = WatchGlyph.aggregateState(
            trackKeys: ["t1", "t2"],
            manifest: ["t1"],
            transferStates: [:],
            errorTexts: [:])
        XCTAssertEqual(state, .notOnWatch)
        XCTAssertEqual(fraction, 0.5)
    }

    func testAggregateHasTransferring() {
        let (state, fraction) = WatchGlyph.aggregateState(
            trackKeys: ["t1", "t2"],
            manifest: [],
            transferStates: ["t1": .queued],
            errorTexts: [:])
        XCTAssertEqual(state, .transferring(progress: 0.0))
    }

    func testAggregateHasFailed() {
        let (state, _) = WatchGlyph.aggregateState(
            trackKeys: ["t1"],
            manifest: [],
            transferStates: ["t1": .failed],
            errorTexts: [:])
        XCTAssertEqual(state, .failed)
    }

    func testAggregateEmptyTrackKeys() {
        let (state, fraction) = WatchGlyph.aggregateState(
            trackKeys: [],
            manifest: [],
            transferStates: [:],
            errorTexts: [:])
        XCTAssertEqual(state, .notOnWatch)
        XCTAssertEqual(fraction, 0.0)
    }
}
