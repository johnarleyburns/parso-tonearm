import Testing
@testable import TonearmCore

@Suite struct WatchGlyphStateTests {

    @Test func testNotOnWatchByDefault() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: [], transferState: nil, errorText: nil)
        #expect(state == .notOnWatch)
    }

    @Test func testOnWatchWhenInManifest() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: ["t1", "t2"], transferState: nil, errorText: nil)
        #expect(state == .onWatch)
    }

    @Test func testTransferringWhenQueued() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: [], transferState: .queued, errorText: nil)
        #expect(state == .transferring(progress: nil))
    }

    @Test func testTransferringWhenSending() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: [], transferState: .sending, errorText: nil)
        #expect(state == .transferring(progress: nil))
    }

    @Test func testSendingCarriesByteProgressWhenKnown() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: [], transferState: .sending,
                                     errorText: nil, sendingProgress: 0.6)
        #expect(state == .transferring(progress: 0.6))
    }

    @Test func testSentIsStillTransferringUntilWatchReportsInstallation() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: [], transferState: .sent, errorText: nil)
        #expect(state == .transferring(progress: nil))
        #expect(WatchGlyph.state(trackKey: "t1", manifest: ["t1"], transferState: .sent, errorText: nil) == .onWatch)
    }

    @Test func testCollectionStillShowsProgressWhenAppleTransferFinishedButInstallationIsUnknown() {
        let (state, fraction) = WatchGlyph.aggregateState(trackKeys: ["t1"], manifest: [],
            transferStates: ["t1": .sent], errorTexts: [:])
        #expect(state == .transferring(progress: 0))
        #expect(fraction == 0)
    }

    @Test func testFailedWhenTransferFailed() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: [], transferState: .failed, errorText: "timeout")
        #expect(state == .failed)
    }

    @Test func testFailedWithErrorTextOnly() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: [], transferState: nil, errorText: "some error")
        #expect(state == .failed)
    }

    @Test func testTransferringOverridesOnWatch() {
        let state = WatchGlyph.state(trackKey: "t1", manifest: ["t1"], transferState: .queued, errorText: nil)
        #expect(state == .transferring(progress: nil), "transferring should override manifest")
    }

    // MARK: - Aggregate state

    @Test func testAggregateAllOnWatch() {
        let (state, fraction) = WatchGlyph.aggregateState(
            trackKeys: ["t1", "t2"],
            manifest: ["t1", "t2"],
            transferStates: [:],
            errorTexts: [:])
        #expect(state == .onWatch)
        #expect(fraction == 1.0)
    }

    @Test func testAggregateNoneOnWatch() {
        let (state, fraction) = WatchGlyph.aggregateState(
            trackKeys: ["t1", "t2"],
            manifest: [],
            transferStates: [:],
            errorTexts: [:])
        #expect(state == .notOnWatch)
        #expect(fraction == 0.0)
    }

    @Test func testAggregatePartialOnWatch() {
        let (state, fraction) = WatchGlyph.aggregateState(
            trackKeys: ["t1", "t2"],
            manifest: ["t1"],
            transferStates: [:],
            errorTexts: [:])
        #expect(state == .notOnWatch)
        #expect(fraction == 0.5)
    }

    @Test func testAggregateHasTransferring() {
        let (state, _) = WatchGlyph.aggregateState(
            trackKeys: ["t1", "t2"],
            manifest: [],
            transferStates: ["t1": .queued],
            errorTexts: [:])
        #expect(state == .transferring(progress: 0.0))
    }

    @Test func testAggregateHasFailed() {
        let (state, _) = WatchGlyph.aggregateState(
            trackKeys: ["t1"],
            manifest: [],
            transferStates: ["t1": .failed],
            errorTexts: [:])
        #expect(state == .failed)
    }

    @Test func testAggregateEmptyTrackKeys() {
        let (state, fraction) = WatchGlyph.aggregateState(
            trackKeys: [],
            manifest: [],
            transferStates: [:],
            errorTexts: [:])
        #expect(state == .notOnWatch)
        #expect(fraction == 0.0)
    }
}
