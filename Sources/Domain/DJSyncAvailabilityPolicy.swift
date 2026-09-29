import Foundation

public enum DJSyncAvailabilityPolicy {
    public static func canSync(bpm: Double?) -> Bool {
        guard let bpm else { return false }
        return bpm.isFinite && bpm > 0
    }
}
