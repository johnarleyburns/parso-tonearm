import Foundation
import Synchronization

/// Delegate callbacks spawn asynchronous installation work. A background task must
/// wait for that work, not merely for WatchConnectivity to finish invoking delegates.
public final class WatchBackgroundDeliveryTracker: Sendable {
    private let count = Mutex(0)
    public init() {}

    public func begin() { count.withLock { $0 += 1 } }
    public func end() { count.withLock { $0 = max(0, $0 - 1) } }
    public var hasPendingWork: Bool { count.withLock { $0 > 0 } }

    public func waitUntilDrained(sessionHasPending: @Sendable () -> Bool) async {
        while !Task.isCancelled {
            if !sessionHasPending() && !hasPendingWork { return }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
    }
}
