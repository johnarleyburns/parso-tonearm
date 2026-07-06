import Foundation

// MARK: - Failure classification

enum PlaybackFailure: Equatable {
    case permanent
    case transient
}

enum PlaybackFailureClassifier {
    static func classify(httpStatus status: Int) -> PlaybackFailure {
        switch status {
        case 408, 425, 429: return .transient
        case 500...599:     return .transient
        case 400...499:     return .permanent
        default:            return .transient
        }
    }

    static func classify(urlError code: URLError.Code) -> PlaybackFailure {
        switch code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
             .resourceUnavailable:
            return .transient
        case .badURL, .unsupportedURL, .fileDoesNotExist,
             .cannotDecodeContentData, .cannotDecodeRawData:
            return .permanent
        default:
            return .transient
        }
    }
}

// MARK: - Retry policy

struct RetryPolicy: Equatable {
    var baseDelay: TimeInterval = 0.5
    var maxDelay: TimeInterval = 8
    var jitterFraction: Double = 0.25
    var maxAttemptsPerItem: Int = 4
    var maxConsecutiveSkips: Int = 4

    func delay(forAttempt k: Int, rand: Double = 0.5) -> TimeInterval {
        let exp = baseDelay * pow(2, Double(max(0, k)))
        let capped = min(maxDelay, exp)
        let jitter = capped * jitterFraction * (2 * rand - 1)
        return max(0, capped + jitter)
    }

    func shouldRetry(afterAttempt k: Int, failure: PlaybackFailure) -> Bool {
        failure == .transient && (k + 1) < maxAttemptsPerItem
    }
}

// MARK: - Stall state machine

struct StallModel {
    let maxConsecutiveSkips: Int

    private(set) var loadGeneration = 0
    private(set) var readyGeneration = -1
    private(set) var confirmedGeneration = -1
    private(set) var consecutiveSkips = 0

    init(maxConsecutiveSkips: Int = 4) { self.maxConsecutiveSkips = maxConsecutiveSkips }

    enum Verdict: Equatable {
        case ignoreStale
        case healthy
        case skip
        case giveUp
    }

    mutating func beginLoad() -> Int { loadGeneration += 1; return loadGeneration }

    mutating func markReady(generation: Int) {
        if generation == loadGeneration { readyGeneration = generation }
    }

    mutating func confirmPlayback(generation: Int) {
        if generation == loadGeneration {
            confirmedGeneration = generation
            consecutiveSkips = 0
        }
    }

    mutating func resetSkipStreak() { consecutiveSkips = 0 }

    mutating func evaluateStall(generation: Int, autoPlay: Bool) -> Verdict {
        guard generation == loadGeneration else { return .ignoreStale }
        if confirmedGeneration == generation { return .healthy }
        if !autoPlay && readyGeneration == generation { return .healthy }
        consecutiveSkips += 1
        return consecutiveSkips >= maxConsecutiveSkips ? .giveUp : .skip
    }
}

// MARK: - In-flight registry

final class InFlightRegistry {
    private let lock = NSLock()
    private var ids = Set<String>()

    @discardableResult
    func begin(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.insert(id).inserted
    }

    func end(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        ids.remove(id)
    }

    func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }
}
