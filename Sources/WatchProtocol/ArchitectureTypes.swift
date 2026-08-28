import Foundation

/// The protocol version both apps speak — the §5 envelope's version. The pre-cutover
/// sync envelope and its separate version constant were deleted in Phase 10.
public enum WatchProtocolVersion {
    public static let current = WatchProtocolEnvelope.currentProtocolVersion
}

/// §7.1 — playback targets are explicit and named. There is no "current device"; a command is
/// always addressed to one of these two.
public enum WatchPlaybackTarget: String, Codable, Sendable {
    case iPhone, watch
    public var userFacingName: String { self == .iPhone ? "iPhone" : "Apple Watch" }
}

/// The coarse connectivity value the UI binds to. `WatchConnectionReducer.State` is the authority;
/// this is its presentation-facing projection, kept as a plain `String`-backed enum so it can be
/// persisted and compared cheaply.
public enum WatchConnectivityState: String, Codable, Sendable {
    case opening, connected, temporarilyUnavailable, unavailable
}
