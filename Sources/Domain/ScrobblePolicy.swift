import Foundation

enum ScrobblePolicy {
    static let minimumTrackDuration: TimeInterval = 30
    static let fourMinuteThreshold: TimeInterval = 240
    static let defaultOptIn = false
    static let privacyStatement = "Scrobbling is off until you connect Last.fm or ListenBrainz. When enabled, Tonearm sends the track title, artist, album, duration, and play time to the service you choose."

    enum Provider: String, CaseIterable, Hashable {
        case lastFM = "Last.fm"
        case listenBrainz = "ListenBrainz"
    }

    struct Track: Equatable, Hashable {
        var id: String
        var title: String
        var artist: String?
        var album: String?
        var duration: TimeInterval

        init(id: String,
             title: String,
             artist: String? = nil,
             album: String? = nil,
             duration: TimeInterval) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
            self.duration = max(0, duration)
        }
    }

    struct Submission: Equatable, Hashable, Identifiable {
        var provider: Provider
        var track: Track
        var playedAt: Date
        var creditedSeconds: TimeInterval

        var id: String {
            "\(provider.rawValue)|\(track.id)|\(playedAtMilliseconds)"
        }

        private var playedAtMilliseconds: Int64 {
            Int64((playedAt.timeIntervalSince1970 * 1_000).rounded())
        }
    }

    struct Session: Equatable {
        var track: Track
        var startedAt: Date
        var lastPosition: TimeInterval
        var creditedSeconds: TimeInterval
        var didSubmit: Bool

        init(track: Track,
             startedAt: Date,
             lastPosition: TimeInterval = 0,
             creditedSeconds: TimeInterval = 0,
             didSubmit: Bool = false) {
            self.track = track
            self.startedAt = startedAt
            self.lastPosition = Self.clamp(lastPosition, duration: track.duration)
            self.creditedSeconds = max(0, creditedSeconds)
            self.didSubmit = didSubmit
        }

        private static func clamp(_ position: TimeInterval, duration: TimeInterval) -> TimeInterval {
            min(max(0, position), duration)
        }
    }

    enum PlaybackEvent: Equatable {
        case start(track: Track, at: Date)
        case progress(position: TimeInterval, isPlaying: Bool, at: Date)
        case pause(position: TimeInterval, at: Date)
        case seek(to: TimeInterval, at: Date)
        case repeatOneRestart(at: Date)
    }

    struct Update: Equatable {
        var session: Session?
        var submission: Submission?
    }

    struct OfflineQueue: Equatable {
        enum Delivery {
            case delivered
            case offline
        }

        struct ReplayResult: Equatable {
            var submissionID: String
            var delivered: Bool
        }

        private(set) var pending: [Submission]
        private(set) var deliveredIDs: Set<String>

        init(pending: [Submission] = [], deliveredIDs: Set<String> = []) {
            self.pending = []
            self.deliveredIDs = deliveredIDs
            for submission in pending {
                record(submission, delivery: .offline)
            }
        }

        mutating func record(_ submission: Submission, delivery: Delivery) {
            guard !hasSeen(submission) else { return }
            switch delivery {
            case .delivered:
                deliveredIDs.insert(submission.id)
            case .offline:
                pending.append(submission)
            }
        }

        func replayBatch() -> [Submission] {
            pending
        }

        mutating func applyReplayResults(_ results: [ReplayResult]) {
            let delivered = Set(results.filter(\.delivered).map(\.submissionID))
            guard !delivered.isEmpty else { return }

            pending.removeAll { submission in
                guard delivered.contains(submission.id) else { return false }
                deliveredIDs.insert(submission.id)
                return true
            }
        }

        private func hasSeen(_ submission: Submission) -> Bool {
            deliveredIDs.contains(submission.id) || pending.contains { $0.id == submission.id }
        }
    }

    static func requiredPlaySeconds(for duration: TimeInterval) -> TimeInterval? {
        guard duration.isFinite, duration >= minimumTrackDuration else { return nil }
        return min(duration * 0.5, fourMinuteThreshold)
    }

    static func isEligible(duration: TimeInterval, creditedSeconds: TimeInterval) -> Bool {
        guard let required = requiredPlaySeconds(for: duration) else { return false }
        return creditedSeconds >= required
    }

    static func reduce(_ session: Session?,
                       event: PlaybackEvent,
                       isOptedIn: Bool,
                       provider: Provider) -> Update {
        switch event {
        case .start(let track, let date):
            return Update(session: Session(track: track, startedAt: date), submission: nil)

        case .progress(let position, let isPlaying, _):
            guard var session else { return Update(session: nil, submission: nil) }
            let normalizedPosition = clamp(position, duration: session.track.duration)
            if isPlaying {
                session.creditedSeconds += max(0, normalizedPosition - session.lastPosition)
            }
            session.lastPosition = normalizedPosition
            return submitIfNeeded(session, isOptedIn: isOptedIn, provider: provider)

        case .pause(let position, _), .seek(let position, _):
            guard var session else { return Update(session: nil, submission: nil) }
            session.lastPosition = clamp(position, duration: session.track.duration)
            return Update(session: session, submission: nil)

        case .repeatOneRestart(let date):
            guard let session else { return Update(session: nil, submission: nil) }
            return Update(
                session: Session(track: session.track, startedAt: date),
                submission: nil
            )
        }
    }

    private static func submitIfNeeded(_ session: Session,
                                       isOptedIn: Bool,
                                       provider: Provider) -> Update {
        var session = session
        guard isOptedIn,
              !session.didSubmit,
              isEligible(duration: session.track.duration, creditedSeconds: session.creditedSeconds) else {
            return Update(session: session, submission: nil)
        }

        session.didSubmit = true
        return Update(
            session: session,
            submission: Submission(
                provider: provider,
                track: session.track,
                playedAt: session.startedAt,
                creditedSeconds: session.creditedSeconds
            )
        )
    }

    private static func clamp(_ position: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard position.isFinite else { return 0 }
        return min(max(0, position), max(0, duration))
    }
}
