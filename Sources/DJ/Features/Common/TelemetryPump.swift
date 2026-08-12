import Foundation
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The display-rate telemetry pump (§40.3, plan 4.6): a `CADisplayLink` that
/// hands every tick to the session view model, which samples the engine's
/// published atomics (never blocking on the RT thread). ProMotion-aware — the
/// preferred frame range is 60–120 Hz — and throttled to 30 Hz whenever
/// `thermalState >= .serious` (NFR-THERM-4). The view model pauses it when the
/// app leaves the foreground; a background session needs no meters (§40.3).
///
/// The display link is the platform's native one — `CADisplayLink` on iOS,
/// `NSScreen.displayLink` on macOS 14+ — so the SPM package still builds for
/// the `swift test` host. With no screen (headless CI) `start()` is a no-op
/// and the pump simply never ticks. `stop()` invalidates the link (the caller
/// owns the pump lifetime — the session view model ends it).
@MainActor
public final class TelemetryPump {

    /// The link's target. A class is required for `target:selector:`; the
    /// closure is what the view model actually runs.
    private final class Target: NSObject, @unchecked Sendable {
        private let tick: @MainActor () -> Void
        init(tick: @escaping @MainActor () -> Void) {
            self.tick = tick
        }
        @objc func displayLinkTick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { tick() }
        }
    }

    /// The throttle tick counter, boxed so the link's closure never captures
    /// the pump itself (a display link would otherwise outlive its owner).
    private final class Counter: @unchecked Sendable {
        var count = 0
    }

    private let counter: Counter
    private let target: Target
    private var displayLink: CADisplayLink?

    public init(tick: @escaping @MainActor () -> Void) {
        let counter = Counter()
        self.counter = counter
        self.target = Target(tick: { [weak counter] in
            guard let counter else { return }
            counter.count += 1
            let factor = TelemetryPump.samplingFactor(thermalState: ProcessInfo.processInfo.thermalState)
            guard counter.count % factor == 0 else { return }
            tick()
        })
    }

    public func start() {
        guard displayLink == nil else { return }
        let selector = #selector(TelemetryPump.Target.displayLinkTick(_:))
        #if canImport(UIKit)
        displayLink = CADisplayLink(target: target, selector: selector)
        #elseif canImport(AppKit)
        displayLink = NSScreen.main?.displayLink(target: target, selector: selector)
        #endif
        guard let link = displayLink else { return } // headless: no screen, no tick
        link.preferredFrameRateRange = Self.preferredRange()
        link.add(to: .main, forMode: .common)
    }

    public func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    public var isPaused: Bool { displayLink?.isPaused ?? true }

    public func setPaused(_ paused: Bool) {
        displayLink?.isPaused = paused
    }

    /// The ProMotion-aware preferred frame range (§40.3). At `.serious` the
    /// pump drops to a fixed 30 Hz so a hot device stops spending display
    /// cycles on meters (NFR-THERM-4).
    public static func preferredRange(thermalState: ProcessInfo.ThermalState =
        ProcessInfo.processInfo.thermalState) -> CAFrameRateRange {
        if isThrottled(thermalState: thermalState) {
            return CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        }
        return CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
    }

    /// Tick-sampling factor: 1 at normal thermal state, 2 while throttled at
    /// `.serious` — the pump yields every other frame so the UI stays calm
    /// when the device is hot.
    public static func samplingFactor(thermalState: ProcessInfo.ThermalState) -> Int {
        isThrottled(thermalState: thermalState) ? 2 : 1
    }

    /// True when the thermal state is at or above `.serious` (the pump's
    /// throttle point, §40.3).
    public static func isThrottled(thermalState: ProcessInfo.ThermalState) -> Bool {
        severity(thermalState) >= 2
    }

    private static func severity(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}
