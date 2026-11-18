import Foundation
import Testing

@testable import TonearmCore

@Suite struct ScrobblePolicyTests {
    @Test func testBoundaryAtExactlyFiftyPercent() {
        let track = self.track(duration: 100)
        var update = ScrobblePolicy.reduce(nil, event: .start(track: track, at: date(0)),
                                           isOptedIn: true, provider: .lastFM)

        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 49.99, isPlaying: true, at: date(10)),
                                       isOptedIn: true, provider: .lastFM)
        #expect(update.submission == nil)

        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 50, isPlaying: true, at: date(11)),
                                       isOptedIn: true, provider: .lastFM)
        #expect(update.submission?.track.id == "track")
        #expect(abs((update.submission?.creditedSeconds ?? -1) - 50) <= 0.001)
    }

    @Test func testFourMinuteRuleCapsLongTrackThreshold() {
        #expect(ScrobblePolicy.requiredPlaySeconds(for: 1_000) == 240)

        let track = self.track(duration: 1_000)
        var update = ScrobblePolicy.reduce(nil, event: .start(track: track, at: date(0)),
                                           isOptedIn: true, provider: .listenBrainz)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 239.9, isPlaying: true, at: date(239)),
                                       isOptedIn: true, provider: .listenBrainz)
        #expect(update.submission == nil)

        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 240, isPlaying: true, at: date(240)),
                                       isOptedIn: true, provider: .listenBrainz)
        #expect(update.submission?.provider == .listenBrainz)
    }

    @Test func testMinimumTrackLength() {
        #expect(ScrobblePolicy.requiredPlaySeconds(for: 29.999) == nil)
        #expect(ScrobblePolicy.requiredPlaySeconds(for: 30) == 15)

        let short = self.track(duration: 29.999)
        var update = ScrobblePolicy.reduce(nil, event: .start(track: short, at: date(0)),
                                           isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 29.999, isPlaying: true, at: date(30)),
                                       isOptedIn: true, provider: .lastFM)
        #expect(update.submission == nil)
    }

    @Test func testSeekingBackwardsDoesNotSubtractOrDoubleCountSeekJump() {
        let track = self.track(duration: 100)
        var update = ScrobblePolicy.reduce(nil, event: .start(track: track, at: date(0)),
                                           isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 30, isPlaying: true, at: date(30)),
                                       isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .seek(to: 10, at: date(31)),
                                       isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 29.9, isPlaying: true, at: date(50)),
                                       isOptedIn: true, provider: .lastFM)
        #expect(update.submission == nil)

        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 30, isPlaying: true, at: date(51)),
                                       isOptedIn: true, provider: .lastFM)
        #expect(abs((update.submission?.creditedSeconds ?? -1) - 50) <= 0.001)
    }

    @Test func testPausingDoesNotCreditElapsedPositionChanges() {
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
        #expect(update.submission == nil)

        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 70, isPlaying: true, at: date(90)),
                                       isOptedIn: true, provider: .lastFM)
        #expect(abs((update.submission?.creditedSeconds ?? -1) - 50) <= 0.001)
    }

    @Test func testRepeatOneCreatesANewPlayButDoesNotDuplicateWithinAPlay() {
        let track = self.track(duration: 40)
        var update = ScrobblePolicy.reduce(nil, event: .start(track: track, at: date(0)),
                                           isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 20, isPlaying: true, at: date(20)),
                                       isOptedIn: true, provider: .lastFM)
        let first = update.submission

        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 40, isPlaying: true, at: date(40)),
                                       isOptedIn: true, provider: .lastFM)
        #expect(update.submission == nil)

        update = ScrobblePolicy.reduce(update.session, event: .repeatOneRestart(at: date(41)),
                                       isOptedIn: true, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 19.9, isPlaying: true, at: date(60)),
                                       isOptedIn: true, provider: .lastFM)
        #expect(update.submission == nil)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 20, isPlaying: true, at: date(61)),
                                       isOptedIn: true, provider: .lastFM)

        #expect(first != nil)
        #expect(first?.id != update.submission?.id)
        #expect(update.submission?.playedAt == date(41))
    }

    @Test func testOfflineQueueFlushOrderingAndRetry() {
        let a = submission(trackID: "a", at: 1)
        let b = submission(trackID: "b", at: 2)
        let c = submission(trackID: "c", at: 3)
        var queue = ScrobblePolicy.OfflineQueue()

        queue.record(a, delivery: .offline)
        queue.record(b, delivery: .offline)
        queue.record(c, delivery: .offline)

        #expect(queue.replayBatch().map(\.track.id) == ["a", "b", "c"])

        queue.applyReplayResults([
            .init(submissionID: a.id, delivered: true),
            .init(submissionID: b.id, delivered: false),
        ])

        #expect(queue.replayBatch().map(\.track.id) == ["b", "c"])

        queue.applyReplayResults([
            .init(submissionID: b.id, delivered: true),
            .init(submissionID: c.id, delivered: true),
        ])
        #expect(queue.replayBatch().isEmpty)
    }

    @Test func testDuplicateSuppressionForPendingAndDeliveredSubmissions() {
        let submission = submission(trackID: "same", at: 1)
        var queue = ScrobblePolicy.OfflineQueue()

        queue.record(submission, delivery: .offline)
        queue.record(submission, delivery: .offline)
        #expect(queue.replayBatch().count == 1)

        queue.applyReplayResults([.init(submissionID: submission.id, delivered: true)])
        #expect(queue.replayBatch().isEmpty)

        queue.record(submission, delivery: .offline)
        #expect(queue.replayBatch().isEmpty)
    }

    @Test func testScrobblingIsOptInWithPlainPrivacyStatement() {
        let track = self.track(duration: 100)
        var update = ScrobblePolicy.reduce(nil, event: .start(track: track, at: date(0)),
                                           isOptedIn: false, provider: .lastFM)
        update = ScrobblePolicy.reduce(update.session, event: .progress(position: 100, isPlaying: true, at: date(100)),
                                       isOptedIn: false, provider: .lastFM)

        #expect(!ScrobblePolicy.defaultOptIn)
        #expect(update.submission == nil)
        #expect(ScrobblePolicy.privacyStatement.contains("Last.fm"))
        #expect(ScrobblePolicy.privacyStatement.contains("ListenBrainz"))
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
