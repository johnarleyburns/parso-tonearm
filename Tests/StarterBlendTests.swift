import os
import XCTest
@testable import TonearmCore

private func jt(_ id: String) -> JamendoTrack {
        JamendoTrack(id: id, name: "T\(id)", duration: 100, artistID: nil, artistName: "A",
                     albumName: nil, albumID: nil, licenseCcurl: nil,
                     audio: "https://example.test/\(id).mp3", audiodownload: nil,
                     audiodownloadAllowed: nil, albumImage: nil, musicinfo: nil)
}

@MainActor
private final class StartLog {
    var requests: [StarterPlayRequest] = []
}

@MainActor
final class StarterBlendTests: XCTestCase {

    func testCatalogIsDeterministicAndComplete() {
        XCTAssertGreaterThanOrEqual(StarterBlendCatalog.blends.count, 6)
        XCTAssertEqual(Set(StarterBlendCatalog.blends.map(\.id)).count, StarterBlendCatalog.blends.count)
        for blend in StarterBlendCatalog.blends {
            XCTAssertFalse(blend.jamendoTrackIDs.isEmpty)
            XCTAssertEqual(blend.document, blend.document)
            XCTAssertEqual(blend.document.origin, .starter)
            XCTAssertEqual(blend.document.occurrences.count, blend.jamendoTrackIDs.count)
            XCTAssertEqual(blend.document.edges.map(\.requestedStyle),
                           Array(repeating: blend.requestedStyle, count: blend.jamendoTrackIDs.count - 1))
        }
    }

    func testCatalogSubtitlesNameTheirCuratedSubgenre() {
        let expected = [
            "starter.morning-light": "Singer-Songwriter",
            "starter.deep-focus": "Ambient",
            "starter.night-drive": "Synthwave",
            "starter.acoustic-evening": "Singer-Songwriter",
            "starter.upbeat-energy": "Dance Pop",
            "starter.rainy-day": "Contemporary Piano"
        ]
        XCTAssertEqual(Set(StarterBlendCatalog.blends.map(\.id)), Set(expected.keys))
        for blend in StarterBlendCatalog.blends {
            XCTAssertTrue(blend.summary.contains(try! XCTUnwrap(expected[blend.id])), blend.id)
        }
    }

    func testPlayProducesOneRequestWithOrderedOccurrences() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let log = StartLog()
        // Jamendo may return tracks in any order.
        let playback = StarterBlendPlayback(
            fetch: { ids in ids.reversed().map { jt($0) } },
            start: { log.requests.append($0) })
        await playback.play(blend)
        let requests = log.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].occurrenceIDs, blend.document.occurrences.map(\.id))
        XCTAssertEqual(requests[0].rows.map(\.track.title), blend.jamendoTrackIDs.map { "T\($0)" })
    }

    func testFailureIsCardScopedAndRetryable() async {
        let failing = StarterBlendCatalog.blends[0], other = StarterBlendCatalog.blends[1]
        let offline = OSAllocatedUnfairLock(initialState: true)
        let log = StartLog()
        let playback = StarterBlendPlayback(
            fetch: { ids in
                if offline.withLock({ $0 }) && ids == failing.jamendoTrackIDs { throw JamendoGenreError.transport }
                return ids.map { jt($0) }
            },
            start: { log.requests.append($0) })
        await playback.play(failing)
        guard case .failed = playback.state(for: failing) else { return XCTFail("expected failure") }
        XCTAssertEqual(playback.state(for: other), .idle)
        await playback.play(other)
        XCTAssertEqual(log.requests.count, 1)
        offline.withLock { $0 = false }
        await playback.play(failing)
        XCTAssertEqual(playback.state(for: failing), .idle)
        XCTAssertEqual(log.requests.count, 2)
    }

    func testRepeatedTapWhileInFlightStartsOnce() async {
        let blend = StarterBlendCatalog.blends[0]
        let log = StartLog()
        let playback = StarterBlendPlayback(
            fetch: { ids in try await Task.sleep(nanoseconds: 50_000_000); return ids.map { jt($0) } },
            start: { log.requests.append($0) })
        async let a: Void = playback.play(blend)
        async let b: Void = playback.play(blend)
        _ = await (a, b)
        XCTAssertEqual(log.requests.count, 1)
    }

    func testPreparedBlendStartsOnlyAfterEveryEdgeIsReady() async {
        let blend = StarterBlendCatalog.blends[0]
        let log = StartLog()
        let playback = StarterBlendPlayback(
            fetch: { ids in ids.map { jt($0) } },
            prepare: { rows, progress in
                XCTAssertTrue(log.requests.isEmpty, "must not play before preparation")
                for row in rows { progress(row.track.id ?? 0, .ready) }
            },
            start: { log.requests.append($0) })
        await playback.play(blend)
        XCTAssertEqual(log.requests.count, 1)
        XCTAssertTrue(log.requests[0].isPrepared)
    }

    func testOfflinePreparationIsVisibleAndOffersSequentialFallbackAndRetry() async {
        let blend = StarterBlendCatalog.blends[0]
        let log = StartLog()
        let offline = OSAllocatedUnfairLock(initialState: true)
        let playback = StarterBlendPlayback(
            fetch: { ids in ids.map { jt($0) } },
            prepare: { rows, progress in
                for (i, row) in rows.enumerated() {
                    if offline.withLock({ $0 }) && i == 1 { progress(row.track.id ?? 0, .waitingForNetwork); return }
                    progress(row.track.id ?? 0, .ready)
                }
            },
            start: { log.requests.append($0) })
        await playback.play(blend)
        guard case .unprepared(let reason) = playback.state(for: blend) else { return XCTFail("expected unprepared") }
        XCTAssertTrue(reason.contains("offline"))
        XCTAssertTrue(log.requests.isEmpty)

        offline.withLock { $0 = false }
        await playback.play(blend)
        XCTAssertEqual(log.requests.count, 1)
        XCTAssertTrue(log.requests[0].isPrepared)

        offline.withLock { $0 = true }
        await playback.play(blend)
        playback.playSequentially(blend)
        XCTAssertEqual(log.requests.count, 2)
        XCTAssertFalse(log.requests[1].isPrepared)
    }

    func testInterruptedPreparationDoesNotStart() async {
        let blend = StarterBlendCatalog.blends[0]
        let log = StartLog()
        let playback = StarterBlendPlayback(
            fetch: { ids in ids.map { jt($0) } },
            prepare: { rows, progress in
                progress(rows[0].track.id ?? 0, .ready)
                progress(rows[1].track.id ?? 0, .cancelled)
            },
            start: { log.requests.append($0) })
        await playback.play(blend)
        guard case .unprepared(let reason) = playback.state(for: blend) else { return XCTFail("expected unprepared") }
        XCTAssertTrue(reason.contains("interrupted"))
        XCTAssertTrue(log.requests.isEmpty)
    }
}
