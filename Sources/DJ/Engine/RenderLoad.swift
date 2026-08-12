import Foundation
import Synchronization

/// Render-load metering measured inside the render callback (§34.3, plan §2.12).
///
/// The callback records `mach_absolute_time()` at the top and bottom of its
/// body and publishes the elapsed time in nanoseconds through one relaxed
/// atomic store — no timing computation crosses the RT boundary (§34.3). The UI
/// reads `lastRenderNanos` at display cadence and divides by the buffer period
/// to show the CPU% (mockup `ipad/07`'s status bar; §34.2).
public final class RenderLoad: Sendable {

    private let lastNanos = Atomic<UInt64>(0)
    private let timebaseNumer: UInt64
    private let timebaseDenom: UInt64

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebaseNumer = UInt64(info.numer)
        timebaseDenom = UInt64(info.denom)
    }

    /// Callback entry. Returns the `mach_absolute_time` start tick.
    @inline(__always)
    public func startTicks() -> UInt64 {
        mach_absolute_time()
    }

    /// Callback exit. Publishes the render duration in nanoseconds (relaxed
    /// atomic store — the only RT-side timing work, §34.3).
    @inline(__always)
    public func endTicks(_ startTicks: UInt64) {
        let ticks = mach_absolute_time() - startTicks
        let nanos = ticks * timebaseNumer / timebaseDenom
        lastNanos.store(nanos, ordering: .relaxed)
    }

    /// Zero the meter (control side, e.g. before a burst).
    public func reset() {
        lastNanos.store(0, ordering: .relaxed)
    }

    /// The most recent callback's render time in nanoseconds.
    public var lastRenderNanos: UInt64 {
        lastNanos.load(ordering: .relaxed)
    }

    /// Render load as time-over-period, in (0, ∞). `periodNanos` is the buffer
    /// period (128 frames @ 48 kHz ≈ 2 666 667 ns; 256 ≈ 5 333 333 ns). Zero
    /// when nothing has rendered yet.
    public func loadRatio(periodNanos: UInt64) -> Double {
        let last = lastNanos.load(ordering: .relaxed)
        guard last > 0 else { return 0 }
        return Double(last) / Double(periodNanos)
    }
}
