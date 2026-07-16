import Foundation

public struct PrefetchDepthPolicy {
    public static let minimum = 0
    public static let maximum = 5

    public static func clamp(_ value: Int) -> Int {
        min(maximum, max(minimum, value))
    }
}
