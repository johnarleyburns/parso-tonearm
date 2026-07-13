import XCTest

@testable import Tonearm

final class ScrobblePolicyTests: XCTestCase {
    func testBoundaryAtExactlyFiftyPercent() {
        let track = self.track(duration: 100)
        var update = ScrobblePolicy.reduce(nil, event: .start(track: track, at: date(0)),
                                           isOptedIn: true, provider: .lastFM)

        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 49.99, isPlaying: true, at: date(10)),
                                       isOptedIn: true, provider: .lastFM)
        XCTAssertNil(update.submission)

        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 50, isPlaying: true, at: date(11)),
                                       isOptedIn: true, provider: .lastFM)
        XCTAssertEqual(update.submission?.track.id, "track")
        XCTAssertEqual(update.submission?.creditedSeconds ?? -1, 50, accuracy: 0.001)
    }

    func testFourMinuteRuleCapsLongTrackThreshold() {
        XCTAssertEqual(ScrobblePolicy.requiredPlaySeconds(for: 1_000), 240)

        let track = self.track(duration: 1_000)
        var update = ScrobblePolicy.reduce(nil, event: .start(track: track, at: date(0)),
                                           isOptedIn: true, provider: .listenBrainz)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 239.9, isPlaying: true, at: date(239)),
                                       isOptedIn: true, provider: .listenBrainz)
        XCTAssertNil(update.submission)

        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 240, isPlaying: true, at: date(240)),
                                       isOptedIn: true, provider: .listenBrainz)
        XCTAssertEqual(update.submission?.provider, .listenBrainz)
    }

    func testMinimumTrackLength() {
        XCTAssertNil(ScrobblePolicy.requiredPlaySeconds(for: 29.999))
        XCTAssertEqual(ScrobblePolicy.requiredPlaySeconds(for: 30), 15)

        let short = self.track(duration: 29.999)
        var update = ScrobblePolicy.reduce(nil, event: .start(track: short, at: date(0)),
                                           isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 29.999, isPlaying: true, at: date(30)),
                                       isOptedIn: true, provider: .lastFM)
        XCTAssertNil(update.submission)
    }

    func testSeekingBackwardsDoesNotSubtractOrDoubleCountSeekJump() {
        let track = self.track(duration: 100)
        var update = ScrobblePolicy.reduce(nil, event: .start(track: track, at: date(0)),
                                           isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 30, isPlaying: true, at: date(30)),
                                       isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .seek(to: 10, at: date(31)),
                                       isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 29.9, isPlaying: true, at: date(50)),
                                       isOptedIn: true, provider: .lastFM)
        XCTAssertNil(update.submission)

        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 30, isPlaying: true, at: date(51)),
                                       isOptedIn: true, provider: .lastFM)
        XCTAssertEqual(update.submission?.creditedSeconds ?? -1, 50, accuracy: 0.001)
    }

    func testPausingDoesNotCreditElapsedPositionChanges() {
        let track = self.track(duration: 100)
        var update = ScrobblePolicy.reduce(nil, event: .start(track: track, at: date(0)),
                                           isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 20, isPlaying: true, at: date(20)),
                                       isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .pause(position: 20, at: date(21)),
                                       isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 40, isPlaying: false, at: date(60)),
                                       isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 45, isPlaying: true, at: date(65)),
                                       isOptedIn: true, provider: .lastFM)
        XCTAssertNil(update.submission)

        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 70, isPlaying: true, at: date(90)),
                                       isOptedIn: true, provider: .lastFM)
        XCTAssertEqual(update.submission?.creditedSeconds ?? -1, 50, accuracy: 0.001)
    }

    func testRepeatOneCreatesANewPlayButDoesNotDuplicateWithinAPlay() {
        let track = self.track(duration: 40)
        var update = ScrobblePolicy.reduce(nil, event: .start(track: track, at: date(0)),
                                           isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 20, isPlaying: true, at: date(20)),
                                       isOptedIn: true, provider: .lastFM)
        let first = update.submission

        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 40, isPlaying: true, at: date(40)),
                                       isOptedIn: true, provider: .lastFM)
        XCTAssertNil(update.submission)

        update = ScrobblePolicy.reduce(update.session, event: .repeatOneRestart(at: date(41)),
                                       isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 19.9, isPlaying: true, at: date(60)),
                                       isOptedIn: true, provider: .lastFM)
        XCTAssertNil(update.submission)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 20, isPlaying: true, at: date(61)),
                                       isOptedIn: true, provider: .lastFM)

        XCTAssertNotNil(first)
        XCTAssertNotEqual(first?.id, update.submission?.id)
        XCTAssertEqual(update.submission?.playedAt, date(41))
    }

    func testOfflineQueueFlushOrderingAndRetry() {
        let a = submission(trackID: "a", at: 1)
        let b = submission(trackID: "b", at: 2)
        let c = submission(trackID: "c", at: 3)
        var queue = ScrobblePolicy.OfflineQueue()

        queue.record(a, delivery: .offline)
        queue.record(b, delivery: .offline)
        queue.record(c, delivery: .offline)

        XCTAssertEqual(queue.replayBatch().map(\.track.id), ["a", "b", "c"])

        queue.applyReplayResults([
            .init(submissionID: a.id, delivered: true),
            .init(submissionID: b.id, delivered: false),
        ])

        XCTAssertEqual(queue.replayBatch().map(\.track.id), ["b", "c"])

        queue.applyReplayResults([
            .init(submissionID: b.id, delivered: true),
            .init(submissionID: c.id, delivered: true),
        ])
        XCTAssertTrue(queue.replayBatch().isEmpty)
    }

    func testDuplicateSuppressionForPendingAndDeliveredSubmissions() {
        let submission = submission(trackID: "same", at: 1)
        var queue = ScrobblePolicy.OfflineQueue()

        queue.record(submission, delivery: .offline)
        queue.record(submission, delivery: .offline)
        XCTAssertEqual(queue.replayBatch().count, 1)

        queue.applyReplayResults([.init(submissionID: submission.id, delivered: true)])
        XCTAssertTrue(queue.replayBatch().isEmpty)

        queue.record(submission, delivery: .offline)
        XCTAssertTrue(queue.replayBatch().isEmpty)
    }

    func testScrobblingIsOptInWithPlainPrivacyStatement() {
        let track = self.track(duration: 100)
        var update = ScrobblePolicy.reduce(nil, event: .start(track: track, at: date(0)),
                                           isOptedIn: false, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 100, isPlaying: true, at: date(100)),
                                       isOptedIn: false, provider: .lastFM)

        XCTAssertFalse(ScrobblePolicy.defaultOptIn)
        XCTAssertNil(update.submission)
        XCTAssertTrue(ScrobblePolicy.privacyStatement.contains("Last.fm"))
        XCTAssertTrue(ScrobblePolicy.privacyStatement.contains("ListenBrainz"))
    }

    private func track(id: String = "track", duration: TimeInterval) -> ScrobblePolicy.Track {
        ScrobblePolicy.Track(id: id, title: "Song", artist: "Artist", album: "Album", duration: duration)
    }

    private func submission(trackID: String, at seconds: TimeInterval) -> ScrobblePolicy.Submission {
        ScrobblePolicy.Submission(
            provider: .lastFM,
            track: track(id: trackID, duration: 180),
            playedAt: date(seconds),
            creditedSeconds: 90
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
