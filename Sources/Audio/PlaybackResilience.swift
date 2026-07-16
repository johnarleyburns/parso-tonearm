import Foundation

// MARK: - Failure classification

public enum PlaybackFailure: Equatable {
    case permanent
    case transient
}

public enum PlaybackFailureClassifier {
    public static func classify(httpStatus status: Int) -> PlaybackFailure {
        switch status {
        case 408, 425, 429: return .transient
        case 500...599:     return .transient
        case 400...499:     return .permanent
        default:            return .transient
        }
    }

    public static func classify(urlError code: URLError.Code) -> PlaybackFailure {
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

public struct RetryPolicy: Equatable {
    public var baseDelay: TimeInterval = 0.5
    public var maxDelay: TimeInterval = 8
    public var jitterFraction: Double = 0.25
    public var maxAttemptsPerItem: Int = 4
    public var maxConsecutiveSkips: Int = 4

    public func delay(forAttempt k: Int, rand: Double = 0.5) -> TimeInterval {
        let exp = baseDelay * pow(2, Double(max(0, k)))
        let capped = min(maxDelay, exp)
        let jitter = capped * jitterFraction * (2 * rand - 1)
        return max(0, capped + jitter)
    }

    public func shouldRetry(afterAttempt k: Int, failure: PlaybackFailure) -> Bool {
        failure == .transient && (k + 1) < maxAttemptsPerItem
    }
}

// MARK: - Stall state machine

public struct StallModel {
    public let maxConsecutiveSkips: Int

    public private(set) var loadGeneration = 0
    public private(set) var readyGeneration = -1
    public private(set) var confirmedGeneration = -1
    public private(set) var consecutiveSkips = 0

    public init(maxConsecutiveSkips: Int = 4) { self.maxConsecutiveSkips = maxConsecutiveSkips }

    public enum Verdict: Equatable {
        case ignoreStale
        case healthy
        case skip
        case giveUp
    }

    public mutating func beginLoad() -> Int { loadGeneration += 1; return loadGeneration }

    public mutating func markReady(generation: Int) {
        if generation == loadGeneration { readyGeneration = generation }
    }

    public mutating func confirmPlayback(generation: Int) {
        if generation == loadGeneration {
            confirmedGeneration = generation
            consecutiveSkips = 0
        }
    }

    public mutating func resetSkipStreak() { consecutiveSkips = 0 }

    public mutating func evaluateStall(generation: Int, autoPlay: Bool) -> Verdict {
        guard generation == loadGeneration else { return .ignoreStale }
        if confirmedGeneration == generation { return .healthy }
        if !autoPlay && readyGeneration == generation { return .healthy }
        consecutiveSkips += 1
        return consecutiveSkips >= maxConsecutiveSkips ? .giveUp : .skip
    }
}

// MARK: - In-flight registry

public final class InFlightRegistry {
    private let lock = NSLock()
    private var ids = Set<String>()

    @discardableResult
    public func begin(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.insert(id).inserted
    }

    public func end(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        ids.remove(id)
    }

    public func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }
}
