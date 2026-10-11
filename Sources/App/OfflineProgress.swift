import Foundation


/// Adding the Mood Starter tracks to the library, chunk by chunk.
struct StarterMergeProgress: Equatable {
    var added: Int
    var total: Int
    var since: Date
    var paused: Bool
    var failure: String?

    var fraction: Double { total > 0 ? Double(added) / Double(total) : 0 }
}

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
