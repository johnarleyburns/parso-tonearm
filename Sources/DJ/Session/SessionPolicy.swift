import Foundation

/// The pure audio-session decision table (spec §34A.3–34A.4, plan §2.4).
///
/// `AVAudioSession` exists only on iOS, so none of this module imports it: the
/// route/interruption → response mapping below is a deterministic pure function
/// over plain value types, unit-tested on every host (including the `swift test`
/// macOS host). The thin `AudioSessionCoordinator` shell (§34A.2) does the
/// notification marshalling and the `AVAudioSession` calls on iOS; it has nothing
/// to decide.
///
/// This is the one place the session's behaviour is defined, so AT-SESS-* is
/// testable without a device (plan §2.4, §2.11): every row of §34A.3/34A.4 maps
/// to exactly one `Response`.
public enum SessionPolicy {

    // MARK: - Mode

    /// The session's three sanctioned configurations (§34A.1). There is no
    /// fourth. The category/options for each are platform-conditional (they are
    /// `AVAudioSession` values) and live in `AudioSessionCoordinator`; what the
    /// policy needs to decide — whether a buffer is requested, and how small —
    /// is pure and lives here.
    public enum Mode: Sendable, Equatable {
        case listening
        case performing
        case performingWithTalkover

        /// `true` for the two performance modes: a small IO buffer is wanted
        /// and the request is part of negotiation.
        public var requestsPreferredBuffer: Bool {
            switch self {
            case .listening: false
            case .performing, .performingWithTalkover: true
            }
        }

        /// The buffer we ask for in performance modes, in seconds (128 frames
        /// @ 48 kHz, spec §34.1). Listening leaves the system default alone.
        public var preferredIOBufferDuration: TimeInterval? {
            switch self {
            case .listening: nil
            case .performing, .performingWithTalkover: 128.0 / 48_000.0
            }
        }
    }

    // MARK: - Granted (read-back)

    /// The negotiated session values, always read back from the system rather
    /// than assumed from the request (§34A.2, FR-SESS-2). `roundTripMillis` is
    /// what the UI and the FR-SESS-4 Bluetooth warning display.
    public struct Granted: Sendable, Equatable {
        /// The granted IO buffer duration, seconds.
        public var ioBufferDuration: TimeInterval
        public var sampleRate: Double
        public var outputLatency: TimeInterval
        public var inputLatency: TimeInterval
        public var outputChannels: Int
        public var routeName: String
        /// True when the current route has a Bluetooth output.
        public var isBluetooth: Bool

        public init(ioBufferDuration: TimeInterval,
                    sampleRate: Double,
                    outputLatency: TimeInterval,
                    inputLatency: TimeInterval,
                    outputChannels: Int,
                    routeName: String,
                    isBluetooth: Bool) {
            self.ioBufferDuration = ioBufferDuration
            self.sampleRate = sampleRate
            self.outputLatency = outputLatency
            self.inputLatency = inputLatency
            self.outputChannels = outputChannels
            self.routeName = routeName
            self.isBluetooth = isBluetooth
        }

        /// Round-trip latency in milliseconds — the honest figure for a
        /// performer (§34.2, FR-SESS-4, AT-SESS-5).
        public var roundTripMillis: Double {
            (ioBufferDuration * 2 + outputLatency) * 1000
        }
    }

    // MARK: - Route changes (§34A.3)

    public enum RouteChangeReason: Sendable, Equatable {
        case oldDeviceUnavailable
        case newDeviceAvailable
        case categoryChange
        case override
        case routeConfigurationChange
        case unknown
    }

    /// Everything the decision needs to know about a route change. The
    /// coordinator fills this from the `AVAudioSessionRouteChangeReason` and the
    /// before/after granted state; the mapping below never touches iOS types.
    public struct RouteChange: Sendable, Equatable {
        public var reason: RouteChangeReason
        /// True when the granted sample rate changed. Decided *before* the
        /// reason row because a rate change wins over every reason (§34A.3).
        public var sampleRateChanged: Bool
        /// True when the session is currently in a performance mode.
        public var isPerforming: Bool
        /// True when the new route's output is Bluetooth.
        public var isBluetooth: Bool

        public init(reason: RouteChangeReason,
                    sampleRateChanged: Bool,
                    isPerforming: Bool,
                    isBluetooth: Bool) {
            self.reason = reason
            self.sampleRateChanged = sampleRateChanged
            self.isPerforming = isPerforming
            self.isBluetooth = isBluetooth
        }
    }

    // MARK: - Interruptions (§34A.4)

    public enum InterruptionPhase: Sendable, Equatable {
        case began
        case ended
    }

    public struct Interruption: Sendable, Equatable {
        public var phase: InterruptionPhase
        /// From `.ended`'s `AVAudioSessionInterruptionOptionKey.shouldResume`.
        /// Meaningless (and ignored) on `.began`.
        public var shouldResume: Bool
        /// True when re-reading `Granted` after `.ended` shows the sample rate
        /// or channel count changed → the graph must be rebuilt (§34A.4).
        public var formatChanged: Bool

        public init(phase: InterruptionPhase,
                    shouldResume: Bool,
                    formatChanged: Bool) {
            self.phase = phase
            self.shouldResume = shouldResume
            self.formatChanged = formatChanged
        }
    }

    // MARK: - Response

    /// The session's answer to an event. One response per §34A.3/34A.4 row.
    public enum Response: Sendable, Equatable {
        /// Headphones/interface unplugged: pause both decks immediately — never
        /// blast on the built-in speaker. Recording continues (tap is
        /// pre-output) (§34A.3).
        case pauseBothDecks
        /// New device attached: re-read `Granted`, re-negotiate the buffer,
        /// notify the cue router. Decks keep playing when the rate is unchanged.
        case reReadAndRenegotiate
        /// Category/override change: re-read `Granted`, re-assert preferences.
        case reReadAndReassert
        /// Route configuration change (common, benign): re-read only.
        case reReadOnly
        /// Sample-rate change / media-services reset: full graph rebuild
        /// (§34A.5) — node formats are fixed at connect time.
        case rebuildGraph
        /// Route moved to Bluetooth while performing: raise the FR-SESS-4
        /// warning with the measured `roundTripMillis`; never silently degrade.
        case warnBluetoothWhilePerforming
        /// `.began`: flush the recording segment, capture deck transports and
        /// playheads, mark the session interrupted.
        case flushSegmentAndCapturePlayheads
        /// `.ended` with `.shouldResume`: re-activate, restore transports to
        /// the captured playheads — **paused, never auto-play** — and open a new
        /// recording segment. `rebuildGraph` is true when re-reading `Granted`
        /// showed a sample-rate or channel-count change.
        case resume(rebuildGraph: Bool)
        /// `.ended` without `.shouldResume`: remain paused; the UI offers an
        /// explicit Resume.
        case remainPausedOfferResume
    }

    // MARK: - Decision functions

    /// §34A.3's table. A sample-rate change is decided first and overrides the
    /// reason row; the Bluetooth warning is a `.newDeviceAvailable` sub-case.
    public static func response(for routeChange: RouteChange) -> Response {
        if routeChange.sampleRateChanged {
            return .rebuildGraph
        }
        switch routeChange.reason {
        case .oldDeviceUnavailable:
            return .pauseBothDecks
        case .newDeviceAvailable:
            if routeChange.isPerforming && routeChange.isBluetooth {
                return .warnBluetoothWhilePerforming
            }
            return .reReadAndRenegotiate
        case .categoryChange, .override:
            return .reReadAndReassert
        case .routeConfigurationChange, .unknown:
            return .reReadOnly
        }
    }

    /// §34A.4's table. `.began` never resumes anything; `.ended` restores
    /// transports to their captured playheads and never auto-plays.
    public static func response(for interruption: Interruption) -> Response {
        switch interruption.phase {
        case .began:
            return .flushSegmentAndCapturePlayheads
        case .ended:
            guard interruption.shouldResume else { return .remainPausedOfferResume }
            return .resume(rebuildGraph: interruption.formatChanged)
        }
    }

    /// `mediaServicesWereResetNotification`: the same handler as a sample-rate
    /// change — tear down and rebuild everything, restore playheads, keep the
    /// recording's flushed segments (§34A.4). Rare, not optional.
    public static func response(forMediaServicesReset: Void) -> Response {
        .rebuildGraph
    }
}
