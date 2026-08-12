import Foundation
import Synchronization

/// The single-producer (control) / single-consumer (render) command ring (§12.2,
/// plan §2.2).
///
/// A fixed-capacity, power-of-two SPSC ring of POD `RTCommand` values. The
/// control thread calls `tryPush` with release ordering; the render thread calls
/// `drain` at the top of every callback with acquire ordering. Both ends are
/// wait-free and allocation-free: the ring is pre-allocated at init and never
/// grows. `head` is owned by the consumer, `tail` by the producer, each an
/// `Atomic<Int>` from the stdlib `Synchronization` module (iOS 18 / macOS 15 /
/// watchOS 11 — plan §2.2).
public final class CommandRing: @unchecked Sendable {

    /// Power-of-two slot count.
    public let capacity: Int

    /// Number of commands currently queued (control side, for tests/monitoring).
    public var count: Int {
        tail.load(ordering: .relaxed) - head.load(ordering: .relaxed)
    }

    public var isEmpty: Bool { count == 0 }

    private let mask: Int
    private let buffer: UnsafeMutablePointer<RTCommand>
    /// Consumer-owned; only the render thread writes it.
    private let head = Atomic<Int>(0)
    /// Producer-owned; only the control thread writes it.
    private let tail = Atomic<Int>(0)

    public init(capacity: Int) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0,
                     "CommandRing capacity must be a power of two")
        self.capacity = capacity
        self.mask = capacity - 1
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: RTCommand(), count: capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    /// Control side. Non-blocking push; returns `false` when the ring is full
    /// (the caller coalesces or drops non-critical commands — §12.2). The
    /// buffer slot is written before `tail` is published with release ordering,
    /// so the consumer's acquire read of `tail` is guaranteed to observe the
    /// command.
    @discardableResult
    public func tryPush(_ command: RTCommand) -> Bool {
        let consumer = head.load(ordering: .acquiring)
        let producer = tail.load(ordering: .relaxed)
        guard producer - consumer < capacity else { return false }
        buffer[producer & mask] = command
        tail.store(producer + 1, ordering: .releasing)
        return true
    }

    /// Render side. Wait-free drain of every pending command in FIFO order,
    /// applying each through `apply`. `head` is published with release ordering
    /// once the batch is consumed, so the producer's acquire read of `head`
    /// observes the freed slots. Returns the number of commands applied.
    @discardableResult
    public func drain(_ apply: (RTCommand) -> Void) -> Int {
        var consumer = head.load(ordering: .relaxed)
        let producer = tail.load(ordering: .acquiring)
        let applied = producer - consumer
        while consumer < producer {
            apply(buffer[consumer & mask])
            consumer += 1
        }
        head.store(consumer, ordering: .releasing)
        return applied
    }
}
