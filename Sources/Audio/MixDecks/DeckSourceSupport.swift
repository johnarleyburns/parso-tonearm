import Foundation

/// Where a deck's decoded audio comes from (a file decoder in production). Reads may return fewer
/// frames than asked; an empty result is a stall (disk, network), never end of media.
protocol DeckChunkSource: Sendable {
    func read(startFrame: Int64, count: Int) throws -> [[Float]]
}

/// Shared by everything that must stop when a session ends: network reads in flight and decks.
final class StarterCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@Sendable () -> Void] = []
    private var cancelled = false

    func register(_ handler: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            if !cancelled { handlers.append(handler) }
            return cancelled
        }
        if runNow { handler() }
    }

    func cancel() {
        let pending: [@Sendable () -> Void] = lock.withLock {
            cancelled = true
            defer { handlers = [] }
            return handlers
        }
        pending.forEach { $0() }
    }
}
