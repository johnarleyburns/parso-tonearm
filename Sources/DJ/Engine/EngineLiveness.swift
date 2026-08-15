import Foundation

/// Is the graph **actually rendering**? (NFR-REL-2, §34A.5.)
///
/// WHY THIS EXISTS, AND WHY IT IS NOT JUST `engine.isRunning`
/// ---------------------------------------------------------
/// The DJ regression suite found this the hard way: a host slept mid-run, Core
/// Audio called `StopIO`, and because the simulator's audio is a proxy to the
/// host's, the app's render callback was never pulled again. The master clock
/// stopped at bar 171 and the record tap starved — **and the app went on
/// displaying `Stop · 5:07` for another fourteen minutes.** A recording that is
/// dead behind a running timer is the worst kind of failure this app can have,
/// because the user only discovers it after the set.
///
/// The instructive part is *which signals were lying*. `AVAudioEngine.isRunning`
/// still answered `true` — it reports whether the engine was told to run, not
/// whether the hardware is pulling it. No `AVAudioEngineConfigurationChange`
/// arrived either; nothing about the graph's configuration had changed. The only
/// honest signal was the one nobody was watching: **the master clock had stopped
/// advancing while both decks claimed to be playing.**
///
/// So liveness is three signals, in order of how much they can be trusted:
///
/// 1. **The clock is not advancing while a deck plays** — the ground truth. The
///    master sample advances once per render callback, so a frozen clock means
///    the graph is not being rendered, whatever anything else claims.
/// 2. **`isRunning == false`** — the engine knows it was stopped (a media
///    services reset, an unrecoverable route change).
/// 3. **A configuration-change notification** — the fast path, and the only one
///    that says *why*, so the recovery can be the sanctioned rebuild (§34A.5)
///    rather than a blind restart.
///
/// This type is the pure part: no AVFoundation, no clock of its own, fed
/// entirely by its caller, so every transition below is unit-testable without an
/// audio device.
public struct EngineLiveness: Sendable, Equatable {

    /// Why the graph stopped, when it is able to say.
    public enum StopReason: String, Sendable, Equatable, Codable {
        /// `AVAudioEngineConfigurationChange` — a route or format change the
        /// graph cannot absorb without a rebuild (§34A.5).
        case configurationChange
        /// The audio server restarted; every engine object is stale.
        case mediaServicesReset
        /// The engine reports it is not running and did not say why.
        case notRunning
        /// The clock stopped advancing while a deck was playing: the graph is
        /// not being rendered even though nothing reported an error. On a device
        /// this is a hardware or system condition; on a laptop it is usually the
        /// host sleeping.
        case renderStalled

        /// What to tell the user. Honest about the consequence — a stopped
        /// engine means the recording stopped too, and saying so is the entire
        /// point of this file.
        public var message: String {
            switch self {
            case .configurationChange:
                return "The audio route changed and the engine had to stop."
            case .mediaServicesReset:
                return "The system audio server restarted and the engine stopped."
            case .notRunning:
                return "The audio engine stopped."
            case .renderStalled:
                return "The audio engine stopped being rendered."
            }
        }
    }

    public enum State: Sendable, Equatable {
        case live
        /// Stopped, with the reason and whether a recording was in flight when
        /// it happened — the caller needs both to react honestly.
        case stopped(reason: StopReason)
    }

    public private(set) var state: State = .live

    public init() {}
}

/// The watchdog itself: fed samples, answers with the state.
///
/// Deliberately a `struct` with an explicit `observe` rather than a timer that
/// owns a clock — the caller already has a telemetry cadence (§40.3), and a
/// watchdog that cannot be driven from a test is a watchdog nobody trusts.
public struct EngineLivenessMonitor: Sendable {

    /// How long the clock may sit still, with a deck playing, before the graph
    /// is declared stalled.
    ///
    /// Long enough not to fire on a scheduling hiccup or a single dropped
    /// callback, short enough that a user is told inside a phrase rather than
    /// after the set. Two seconds is one bar at 120 BPM.
    public var stallSeconds: Double

    private var lastSample: Int64?
    private var lastAdvance: Date?
    private var stoppedReason: EngineLiveness.StopReason?

    public init(stallSeconds: Double = 2.0) {
        self.stallSeconds = stallSeconds
    }

    /// Report an out-of-band stop (a notification). Takes precedence over the
    /// stall detector because it carries the reason.
    public mutating func report(_ reason: EngineLiveness.StopReason) {
        stoppedReason = reason
    }

    /// Clear the stopped state after a successful recovery, and re-arm the
    /// stall detector so the recovered graph gets a fresh window rather than
    /// being judged on the clock it froze at.
    public mutating func recovered(now: Date = Date()) {
        stoppedReason = nil
        lastSample = nil
        lastAdvance = now
    }

    /// Fold one telemetry sample in and answer with the current state.
    ///
    /// `anyDeckPlaying` is the gate on the stall rule: a clock that is not
    /// advancing because nothing is playing is not a stall, it is a paused
    /// deck, and calling that a failure would make the warning meaningless
    /// exactly when the user is browsing for the next track.
    public mutating func observe(masterSample: Int64,
                                 anyDeckPlaying: Bool,
                                 isRunning: Bool,
                                 now: Date = Date()) -> EngineLiveness.State {
        if let stoppedReason {
            return .stopped(reason: stoppedReason)
        }
        if !isRunning {
            return .stopped(reason: .notRunning)
        }
        guard anyDeckPlaying else {
            // Not a stall — but do not let the idle period count toward one
            // either, or the first bar after pressing play is judged against a
            // clock that has been still for a minute.
            lastSample = masterSample
            lastAdvance = now
            return .live
        }
        if lastSample != masterSample {
            lastSample = masterSample
            lastAdvance = now
            return .live
        }
        guard let lastAdvance else {
            self.lastAdvance = now
            return .live
        }
        if now.timeIntervalSince(lastAdvance) >= stallSeconds {
            stoppedReason = .renderStalled
            return .stopped(reason: .renderStalled)
        }
        return .live
    }
}
