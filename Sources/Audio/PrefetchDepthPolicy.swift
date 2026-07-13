import Foundation

struct PrefetchDepthPolicy {
    static let minimum = 0
    static let maximum = 5

    static func clamp(_ value: Int) -> Int {
        min(maximum, max(minimum, value))
    }
}
