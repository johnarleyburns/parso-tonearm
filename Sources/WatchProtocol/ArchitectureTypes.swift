import Foundation

/// The protocol version both apps speak. Phase 3 makes this the *new* §5 envelope's version; the
/// legacy `WatchSyncEnvelope` keeps its own constant so the two can diverge when Phase 6 retires it.
public enum WatchProtocolVersion {
    public static let current = WatchProtocolEnvelope.currentProtocolVersion
    public static let legacy = WatchSyncEnvelope.currentProtocolVersion
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
