import Foundation

public struct WatchTrackID: Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(value) }
}

public enum WatchProtocolVersion { public static let current = WatchSyncEnvelope.currentProtocolVersion }

public enum WatchPlaybackTarget: String, Codable, Sendable {
    case iPhone, watch
    public var userFacingName: String { self == .iPhone ? "iPhone" : "Apple Watch" }
}

public enum WatchConnectivityState: String, Codable, Sendable {
    case opening, connected, temporarilyUnavailable, unavailable
}
