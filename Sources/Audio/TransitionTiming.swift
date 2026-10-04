import Foundation

/// Pure timing math for a beat-matched blend (field test 2026-10-03: beats in a blend were audibly
/// offset and the blend was abrupt). Kept free of AVFoundation so every rule is unit-testable.
///
/// Both tracks are described in their own item time. The outgoing item advances `outgoingRate`
/// item-seconds per wall second, the incoming one `incomingRate`. The outgoing exit downbeat lines up
/// with the incoming entry downbeat, so one outgoing item-second after the exit corresponds to
/// `incomingRate / outgoingRate` incoming item-seconds.
enum TransitionTiming {
    /// Prepare (create, load, preroll) the incoming item this long before the exit, so a stream
    /// has time to buffer and the start can be scheduled ahead instead of chased.
    static let prepareLeadSeconds: Double = 20
    /// Schedule the synchronized start once the exit is this close.
    static let scheduleLeadSeconds: Double = 2
    /// The shortest lead a host-time start is given, so AVPlayer can honour it.
    static let minimumStartLeadSeconds: Double = 0.1
    /// An incoming track that had to start late fades in over this many seconds from where it
    /// actually started, instead of jumping in at the curve's current level.
    static let lateStartFadeSeconds: Double = 2

    struct Start: Equatable {
        /// Wall seconds from now until the incoming item should start.
        var delaySeconds: Double
        /// Incoming item time to start at, phase-locked to the outgoing beat.
        var incomingItemTime: Double
        /// Whether the start is after the planned exit (the incoming wasn't ready in time).
        var isLate: Bool
    }

    static func ratio(outgoingRate: Double, incomingRate: Double) -> Double {
        guard outgoingRate.isFinite, outgoingRate > 0, incomingRate.isFinite, incomingRate > 0 else { return 1 }
        return incomingRate / outgoingRate
    }

    /// When and where to start the incoming item. Before the exit, it starts exactly at the exit at
    /// `entry`; after it, it starts a moment from now at the entry point advanced by however far the
    /// outgoing track is past the exit, so the beats still coincide.
    static func start(exit: Double, entry: Double, outgoingNow: Double,
                      outgoingRate: Double, incomingRate: Double) -> Start {
        let outRate = outgoingRate.isFinite && outgoingRate > 0 ? outgoingRate : 1
        let untilExit = (exit - outgoingNow) / outRate
        let delay = max(minimumStartLeadSeconds, untilExit)
        let outgoingAtStart = outgoingNow + delay * outRate
        let past = max(0, outgoingAtStart - exit)
        return Start(delaySeconds: delay,
                     incomingItemTime: max(0, entry) + past * ratio(outgoingRate: outRate, incomingRate: incomingRate),
                     isLate: untilExit < minimumStartLeadSeconds)
    }

    /// Where the incoming item should be when the outgoing one is at `outgoingNow`.
    static func expectedIncomingTime(exit: Double, entry: Double, outgoingNow: Double,
                                     outgoingRate: Double, incomingRate: Double) -> Double {
        max(0, entry) + max(0, outgoingNow - exit) * ratio(outgoingRate: outgoingRate, incomingRate: incomingRate)
    }

    enum Correction: Equatable {
        case none
        /// Multiply the incoming rate by this for the next check interval; inaudible with the
        /// spectral time-pitch algorithm and free of the dropout a seek causes.
        case nudgeRate(Double)
        /// Gross misalignment (a stall); only a seek can fix it.
        case seek(toIncomingTime: Double)
    }

    /// Drift = actual − expected incoming time, in incoming item seconds. Small drift is removed
    /// by speeding up or slowing down the incoming track over about a second; a seek is kept for
    /// stalls, because every seek during playback is an audible gap.
    static func correction(driftSeconds drift: Double, expectedIncomingTime: Double) -> Correction {
        guard drift.isFinite, expectedIncomingTime.isFinite else { return .none }
        if abs(drift) <= 0.004 { return .none }
        if abs(drift) >= 0.12 { return .seek(toIncomingTime: expectedIncomingTime) }
        return .nudgeRate(1 - min(max(drift, -0.03), 0.03))
    }

    /// Multiplier on the incoming gain after a late start: 0 at the actual start, 1 after
    /// `lateStartFadeSeconds` of outgoing time.
    static func lateStartGain(outgoingNow: Double, startedAtOutgoing: Double?) -> Double {
        guard let startedAtOutgoing else { return 1 }
        return min(max((outgoingNow - startedAtOutgoing) / lateStartFadeSeconds, 0), 1)
    }
}
