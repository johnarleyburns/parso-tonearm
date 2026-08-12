import Foundation
import Synchronization

/// The double-buffered engine snapshot (§12.2, plan §2.2).
///
/// State too large or too structured for the command ring — a freshly computed
/// beat grid, a swapped-in stem buffer set, a full EQ coefficient set — is
/// built by the control side as an immutable snapshot, then published with a
/// single atomic pointer store. The render thread reads the current pointer
/// once per callback with acquire ordering.
///
/// Reclamation is never the render thread's job: `publish` hands the replaced
/// pointer back to the control side, which passes it to `retire`; `drainRetired`
/// returns it once the render thread has left the callback (§12.2, §46.2).
public final class EngineSnapshot: @unchecked Sendable {

    private let current = Atomic<UnsafeRawPointer?>(nil)
    private let lock = NSLock()
    private var retired: [UnsafeRawPointer] = []

    public init() {}

    /// Control side. Publish a fully-written immutable snapshot with release
    /// ordering. Returns the pointer this call replaced (nil if none), which the
    /// caller must hand to `retire` rather than freeing directly.
    @discardableResult
    public func publish(_ newPointer: UnsafeRawPointer) -> UnsafeRawPointer? {
        current.exchange(newPointer, ordering: .releasing)
    }

    /// Render side. Read the current snapshot pointer once per callback with
    /// acquire ordering. Returns nil if none has been published.
    public func read() -> UnsafeRawPointer? {
        current.load(ordering: .acquiring)
    }

    /// Control side. Add a pointer previously returned by `publish` to the
    /// retire list. It is reclaimed later by `drainRetired` — never on the
    /// render thread.
    public func retire(_ pointer: UnsafeRawPointer) {
        lock.withLock { retired.append(pointer) }
    }

    /// Control side. Claim and clear the retired pointers; the caller may now
    /// free or reuse them. Empty when nothing is pending.
    public func drainRetired() -> [UnsafeRawPointer] {
        lock.withLock {
            let drained = retired
            retired.removeAll(keepingCapacity: true)
            return drained
        }
    }
}
