import Foundation

public enum DJLayoutSwitchPolicy {
    /// The switch is discoverable during the first three entries into DJ,
    /// while an explicit Settings choice continues to keep it visible.
    public static func shouldShow(manualSetting: Bool, sessionCount: Int) -> Bool {
        manualSetting || max(0, sessionCount) < 3
    }
}
