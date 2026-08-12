import Foundation
import Synchronization

/// The master clock snapshot (§30.1): the master-timeline position, the master
/// deck's effective BPM, and its downbeat phase — the value the control side
/// reads once per callback to anchor sync corrections and drive the workspace
/// readouts (mockup `ipad/07`'s beat-phase meter).
///
/// The graph publishes the three components as relaxed atomics each callback
/// (plan 4.6 — the "published snapshot"); `AudioGraph.masterClock` assembles
/// them into this value on the control side. A one-callback skew between the
/// components is harmless: the sync nudge is relative and applied at the next
/// render boundary, and the UI readouts are display-rate (§40.3).
public struct MasterClock: Sendable, Equatable {
    /// The master clock's absolute sample position (§30.1).
    public var masterSample: Int64
    /// The master deck's current effective BPM (grid BPM × rate).
    public var masterBPM: Double
    /// The master deck's downbeat phase (0 ≤ p < 1, within its grid bar).
    public var downbeatPhase: Double

    public init(masterSample: Int64 = 0, masterBPM: Double = 0, downbeatPhase: Double = 0) {
        self.masterSample = masterSample
        self.masterBPM = masterBPM
        self.downbeatPhase = downbeatPhase
    }
}

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
