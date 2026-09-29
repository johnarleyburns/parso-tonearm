import Foundation

/// Interaction constants and clamping for the Focus Deck tempo nudge controls.
/// Keeping this policy in the core target makes the repeat behavior testable
/// without requiring a SwiftUI host or a device.
public enum DJTempoNudgePolicy {
    public static let repeatDelayMilliseconds = 350
    public static let repeatIntervalMilliseconds = 80
    public static let stepPercent = 0.1

    public static func nudgedValue(current: Double, direction: Double,
                                   range: Double) -> Double {
        let limit = max(0, range)
        return min(limit, max(-limit, current + direction * stepPercent))
    }
}
