import Foundation

public enum WatchSessionDisplayState: Equatable {
    case notInstalled
    case installedNotReachable
    case reachable
    case unsupported
}

public struct WatchSessionSnapshot: Equatable {
    public var state: WatchSessionDisplayState
    public var onWatchTrackCount: Int
    public var onWatchBytes: Int64
    public var transferQueueCount: Int
    public var transferFailedCount: Int

    public init(state: WatchSessionDisplayState, onWatchTrackCount: Int = 0,
                onWatchBytes: Int64 = 0, transferQueueCount: Int = 0,
                transferFailedCount: Int = 0) {
        self.state = state
        self.onWatchTrackCount = onWatchTrackCount
        self.onWatchBytes = onWatchBytes
        self.transferQueueCount = transferQueueCount
        self.transferFailedCount = transferFailedCount
    }
}
