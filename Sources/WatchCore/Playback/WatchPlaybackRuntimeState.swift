import Foundation

/// The platform-independent state vocabulary shared by the watch player, diagnostics, and tests.
/// The AVFoundation adapter is responsible for translating platform state into these values.
public enum WatchPlaybackPhase: String, Codable, Equatable, Sendable {
    case idle
    case activating
    case loading
    case ready
    case playing
    case paused
    case waitingForRoute
    case failed
}

public enum WatchItemReadiness: String, Codable, Equatable, Sendable {
    case noItem
    case unknown
    case ready
    case failed
}

public struct WatchPlaybackFailure: Codable, Equatable, Sendable {
    public let code: String
    public let userMessage: String

    public init(code: String, userMessage: String) {
        self.code = code
        self.userMessage = userMessage
    }
}

public struct WatchRouteSnapshot: Codable, Equatable, Sendable {
    public let outputCount: Int
    public let outputPortTypes: [String]

    public init(outputCount: Int = 0, outputPortTypes: [String] = []) {
        self.outputCount = outputCount
        self.outputPortTypes = outputPortTypes
    }
}

public enum WatchAudioActivationResult: Equatable, Sendable {
    case active(route: WatchRouteSnapshot)
    case unavailable(code: String, route: WatchRouteSnapshot)
    case failed(code: String, route: WatchRouteSnapshot)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    public var code: String? {
        switch self {
        case .active: return nil
        case .unavailable(let code, _), .failed(let code, _): return code
        }
    }

    public var route: WatchRouteSnapshot {
        switch self {
        case .active(let route), .unavailable(_, let route), .failed(_, let route): return route
        }
    }
}

public enum WatchItemLoadResult: Equatable, Sendable {
    case ready(durationSeconds: Double)
    case failed(code: String)
    case cancelled

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public enum WatchPlayResult: Equatable, Sendable {
    case playing(rate: Double)
    case failed(code: String)
    case cancelled

    public var isPlaying: Bool {
        if case .playing(let rate) = self { return rate > 0 }
        return false
    }
}

public enum WatchSessionRebuildResult: Equatable, Sendable {
    case ready(durationSeconds: Double)
    case failed(code: String)
    case cancelled
}

/// Pure transition model used to keep requested state separate from confirmed platform state.
public struct WatchPlaybackRuntimeState: Codable, Equatable, Sendable {
    public private(set) var phase: WatchPlaybackPhase = .idle
    public private(set) var generation: Int64 = 0
    public private(set) var trackID: String?
    public private(set) var durationSeconds: Double = 0
    public private(set) var rate: Double = 0
    public private(set) var failure: WatchPlaybackFailure?

    public init() {}

    public mutating func begin(trackID: String, generation: Int64) {
        self.generation = generation
        self.trackID = trackID
        phase = .activating
        durationSeconds = 0
        rate = 0
        failure = nil
    }

    public mutating func waitingForRoute(_ failure: WatchPlaybackFailure) {
        phase = .waitingForRoute
        rate = 0
        self.failure = failure
    }

    public mutating func loading() {
        phase = .loading
        rate = 0
        failure = nil
    }

    public mutating func ready(durationSeconds: Double) {
        phase = .ready
        self.durationSeconds = max(0, durationSeconds)
        rate = 0
        failure = nil
    }

    public mutating func playing(rate: Double) {
        phase = .playing
        self.rate = max(0, rate)
        failure = nil
    }

    public mutating func paused() {
        phase = .paused
        rate = 0
    }

    public mutating func failed(_ failure: WatchPlaybackFailure) {
        phase = .failed
        rate = 0
        self.failure = failure
    }

    public mutating func idle() {
        phase = .idle
        trackID = nil
        durationSeconds = 0
        rate = 0
        failure = nil
    }
}
