import Foundation


struct OfflineProgress: Equatable {
    var sourceID: Int64
    var completed: Int
    var total: Int
    var failed: Bool
    var message: String?

    var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }

    var isDone: Bool {
        completed >= total
    }
}
