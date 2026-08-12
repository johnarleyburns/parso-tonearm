import Foundation

#if canImport(AVAudioSession)
import AVFoundation
#endif

/// The session's three configurations mapped to `AVAudioSession` values
/// (§34A.1). `.mixWithOthers` is deliberately absent for the performance modes —
/// another app's notification sound must never enter the master bus — and
/// `.defaultToSpeaker` is off for talkover, so an explicit output is requested
/// rather than assumed.
#if canImport(AVAudioSession)
extension SessionPolicy.Mode {
    var category: AVAudioSession.Category {
        switch self {
        case .listening, .performing: .playback
        case .performingWithTalkover: .playAndRecord
        }
    }

    var options: AVAudioSession.CategoryOptions {
        switch self {
        case .listening: []
        case .performing: [.allowBluetoothA2DP]
        case .performingWithTalkover: [.allowBluetooth]
        }
    }
}
#endif

/// The audio-session coordinator (spec §34A, plan §2.3, commit 4.2).
///
/// A thin shell and nothing more: it marshals `AVAudioSession` notifications
/// into the pure `SessionPolicy` decision table and performs the sanctioned
/// `AVAudioSession` calls in the normative order (§34A.2). Every behavioural
/// decision lives in `SessionPolicy`; this type decides nothing, which is what
/// keeps AT-SESS-* testable on any host.
///
/// The whole implementation body is `#if canImport(AVAudioSession)`-guarded:
/// macOS has no `AVAudioSession`, so on non-iOS platforms the actor is a minimal
/// stub — the session cannot be entered (it throws `SessionError`) and the
/// response stream stays empty. The pure `SessionPolicy` is what the
/// `AudioSessionMatrixTests` exercise on the macOS host (plan §2.4, §2.11).
public actor AudioSessionCoordinator {

    public enum SessionError: Error, Equatable {
        /// No `AVAudioSession` on this platform; the session cannot be entered.
        case unavailableOnThisPlatform
        /// Performance mode over a Bluetooth route is refused unless explicitly
        /// acknowledged (FR-SESS-4). Carries the measured round-trip latency.
        case bluetoothPerformingRequiresAcknowledgement(roundTripMillis: Double)
    }

    /// The negotiated values of the current session, or nil before the first
    /// `enter`. Always read back from the system (FR-SESS-2); never assumed.
    public private(set) var granted: SessionPolicy.Granted?

    /// The current mode, or `.listening` before the first `enter`.
    public private(set) var mode: SessionPolicy.Mode = .listening

    /// The marshalled responses the engine consumes (pause decks, rebuild graph,
    /// Bluetooth warning, restore transports). Produced on route changes and
    /// interruptions (§34A.3–34A.4).
    public var responses: AsyncStream<SessionPolicy.Response> { responseStream }

    private let responseStream: AsyncStream<SessionPolicy.Response>
    private let responseContinuation: AsyncStream<SessionPolicy.Response>.Continuation

    #if canImport(AVAudioSession)
    private var observers: [NSObjectProtocol] = []
    #endif

    public init() {
        (responseStream, responseContinuation) = AsyncStream.makeStream(
            of: SessionPolicy.Response.self,
            bufferingPolicy: .unbounded)
        #if canImport(AVAudioSession)
        observeSessionEvents()
        #endif
    }

    deinit {
        #if canImport(AVAudioSession)
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        #endif
    }

    /// Enter a session mode with the normative ordering (§34A.2):
    /// **category → preferences → activate → read back**. The read-back
    /// `Granted` is stored and returned — the request is never assumed to have
    /// been honored (FR-SESS-2).
    ///
    /// Performance modes over a Bluetooth route refuse unless
    /// `allowBluetooth` is true — the explicit FR-SESS-4 acknowledgement, with
    /// the measured `roundTripMillis` in the error.
    public func enter(_ mode: SessionPolicy.Mode, allowBluetooth: Bool = false) throws -> SessionPolicy.Granted {
        #if canImport(AVAudioSession)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(mode.category, mode: .default, options: mode.options)
        if let preferred = mode.preferredIOBufferDuration {
            try session.setPreferredIOBufferDuration(preferred)
        }
        try session.setPreferredSampleRate(48_000)
        try session.setActive(true, options: [])
        self.mode = mode
        let granted = Self.snapshot(session)
        self.granted = granted
        if mode.requestsPreferredBuffer && granted.isBluetooth && !allowBluetooth {
            throw SessionError.bluetoothPerformingRequiresAcknowledgement(
                roundTripMillis: granted.roundTripMillis)
        }
        return granted
        #else
        throw SessionError.unavailableOnThisPlatform
        #endif
    }

    // MARK: - Notification marshalling (iOS)

    #if canImport(AVAudioSession)
    private func observeSessionEvents() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] notification in
            let reasonRaw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? UInt.max
            Task { await self?.handleRouteChange(reasonRaw: reasonRaw) }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] notification in
            let typeRaw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? UInt.max
            let optionsRaw = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            Task { await self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw) }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [weak self] _ in
            Task { await self?.handleMediaServicesReset() }
        })
    }

    private func handleRouteChange(reasonRaw: UInt) {
        let session = AVAudioSession.sharedInstance()
        let current = Self.snapshot(session)
        let reason = SessionPolicy.RouteChangeReason(avAudioReason: reasonRaw)
        let sampleRateChanged = granted.map { abs($0.sampleRate - current.sampleRate) > 1 } ?? false
        granted = current
        responseContinuation.yield(SessionPolicy.response(for: SessionPolicy.RouteChange(
            reason: reason,
            sampleRateChanged: sampleRateChanged,
            isPerforming: mode.requestsPreferredBuffer,
            isBluetooth: current.isBluetooth)))
    }

    private func handleInterruption(typeRaw: UInt, optionsRaw: UInt) {
        let type = AVAudioSession.InterruptionType(rawValue: typeRaw) ?? .began
        switch type {
        case .began:
            // Engine is paused by the system; we do not get to refuse. The
            // response flushes the recording segment and captures playheads.
            responseContinuation.yield(SessionPolicy.response(for: SessionPolicy.Interruption(
                phase: .began, shouldResume: false, formatChanged: false)))
        case .ended:
            let session = AVAudioSession.sharedInstance()
            let current = Self.snapshot(session)
            let formatChanged = granted.map {
                abs($0.sampleRate - current.sampleRate) > 1 || $0.outputChannels != current.outputChannels
            } ?? false
            granted = current
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            responseContinuation.yield(SessionPolicy.response(for: SessionPolicy.Interruption(
                phase: .ended, shouldResume: shouldResume, formatChanged: formatChanged)))
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        // The same handler as a sample-rate change: rebuild everything, restore
        // playheads, keep the recording's flushed segments (§34A.4).
        responseContinuation.yield(SessionPolicy.response(forMediaServicesReset: ()))
    }

    private static func snapshot(_ session: AVAudioSession) -> SessionPolicy.Granted {
        let route = session.currentRoute
        let isBluetooth = route.outputs.contains {
            $0.portType == .bluetoothA2DP
                || $0.portType == .bluetoothHFP
                || $0.portType == .bluetoothLE
        }
        return SessionPolicy.Granted(
            ioBufferDuration: session.ioBufferDuration,
            sampleRate: session.sampleRate,
            outputLatency: session.outputLatency,
            inputLatency: session.inputLatency,
            outputChannels: session.outputNumberOfChannels,
            routeName: route.outputs.first?.portName ?? "unknown",
            isBluetooth: isBluetooth)
    }
    #endif
}

#if canImport(AVAudioSession)
extension SessionPolicy.RouteChangeReason {
    init(avAudioReason rawValue: UInt) {
        switch AVAudioSession.RouteChangeReason(rawValue: rawValue) {
        case .newDeviceAvailable: self = .newDeviceAvailable
        case .oldDeviceUnavailable: self = .oldDeviceUnavailable
        case .categoryChange: self = .categoryChange
        case .override: self = .override
        case .routeConfigurationChange: self = .routeConfigurationChange
        default: self = .unknown
        }
    }
}
#endif
