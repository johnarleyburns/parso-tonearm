import XCTest
@testable import TonearmCore

/// Drives the real AudioPlayer fallback token: one ordinary-player fallback per directed
/// occurrence/generation, never recursing into the rejected mixer and never touching the
/// global "Everywhere" preference.
@MainActor
final class LiveMixFallbackTokenTests: XCTestCase {
    private let src = Source(id: 1, kind: .iaItem, iaIdentifier: "x", originalURL: nil, title: "S",
                             addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
                             licenseText: nil, memberCapHit: false)
    private lazy var album = Album(id: 1, sourceId: 1, title: "Album", artist: "Artist")

    private func row(_ trackID: Int64) -> TrackRow {
        let t = Track(id: trackID, albumId: 1, sourceId: 1, title: "T\(trackID)", trackNo: 1, discNo: nil,
                      durationSec: 60, codec: nil, sampleRate: 44_100, bitDepthOrBitrate: nil, sortKey: "\(trackID)")
        let a = Asset(id: trackID, trackId: trackID, kind: .managedCopy, bookmark: nil, relPath: "none/\(trackID).wav",
                      remoteURL: nil, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        return TrackRow(track: t, album: album, source: src, asset: a)
    }

    private func player(duplicate: Bool = false) -> AudioPlayer {
        let p = AudioPlayer.shared
        p.stopMixDecks()
        p.queue = duplicate ? [row(1), row(1)] : [row(1), row(2)]
        p.index = 0
        p.liveMixFallback = nil
        return p
    }

    override func tearDown() async throws {
        AudioPlayer.shared.queue = []
        try await super.tearDown()
    }

    func testTokenBoundToOccurrenceIsConsumedOnceWithoutReenteringMixer() {
        let p = player()
        let token = LiveMixFallbackToken(occurrence: p.queueOccurrences[0], generation: p.mixDecksQueueGeneration)
        p.liveMixFallbackToken = token
        XCTAssertFalse(p.loadCurrentOnMixDecks(row: p.queue[0], autoplay: false))
        XCTAssertNil(p.liveMixFallbackToken, "consumed exactly once")
        XCTAssertNil(p.liveMixFallback, "the rejected mixer admission was not re-entered")
    }

    func testDuplicateTrackOccurrenceIsDistinctFromItsTwin() {
        let p = player(duplicate: true)
        // The token is for the second A; the first A must not consume it as a match.
        p.liveMixFallbackToken = LiveMixFallbackToken(occurrence: p.queueOccurrences[1],
                                                            generation: p.mixDecksQueueGeneration)
        p.index = 0
        _ = p.loadCurrentOnMixDecks(row: p.queue[0], autoplay: false)
        XCTAssertNotNil(p.liveMixFallback, "A at slot 0 is a different occurrence and goes through admission")
    }

    func testQueueReplacementInvalidatesToken() {
        let p = player()
        p.liveMixFallbackToken = LiveMixFallbackToken(occurrence: p.queueOccurrences[0],
                                                            generation: p.mixDecksQueueGeneration)
        p.replaceQueueOccurrences()
        _ = p.loadCurrentOnMixDecks(row: p.queue[0], autoplay: false)
        XCTAssertNotNil(p.liveMixFallback, "a stale token is ignored; the new generation is admitted afresh")
    }

    func testStopAndSeekInvalidateToken() {
        let p = player()
        let token = LiveMixFallbackToken(occurrence: p.queueOccurrences[0], generation: p.mixDecksQueueGeneration)
        p.liveMixFallbackToken = token
        p.stopMixDecks()
        XCTAssertNil(p.liveMixFallbackToken)
        p.liveMixFallbackToken = token
        p.seek(to: 1)
        XCTAssertNil(p.liveMixFallbackToken)
    }

    func testLateDenialWithoutDecksIsIgnoredAndLeavesEverywherePreference() {
        let p = player()
        let before = UserDefaults.standard.object(forKey: "smartTransitionsEverywhere")
        p.mixDecksDenied(index: 0, decision: .gaplessFallback(reason: .preparationFailed))
        XCTAssertNil(p.liveMixFallbackToken)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "smartTransitionsEverywhere") as? Bool, before as? Bool)
    }

    func testFallbackIsLabelledSequentialHandoff() {
        let status = TransitionFallbackStatus(decision: .gaplessFallback(reason: .unavailableSource))
        XCTAssertEqual(status.executed, .sequentialHandoff)
        XCTAssertEqual(status.executed.label, "Sequential handoff")
    }
}
