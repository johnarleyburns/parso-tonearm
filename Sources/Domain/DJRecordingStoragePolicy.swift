import Foundation

/// Storage guardrails for mix recording. The UI remains useful when storage
/// is getting low, but never starts a recording that cannot be completed.
public enum DJRecordingStorageDecision: Equatable, Sendable {
    case allow
    case warn
    case stop
}

public enum DJRecordingStoragePolicy {
    public static let warningBytes: Int64 = 500 * 1_024 * 1_024
    public static let stopBytes: Int64 = 200 * 1_024 * 1_024

    public static func decision(availableBytes: Int64?) -> DJRecordingStorageDecision {
        guard let availableBytes else { return .allow }
        if availableBytes < stopBytes { return .stop }
        if availableBytes < warningBytes { return .warn }
        return .allow
    }
}
