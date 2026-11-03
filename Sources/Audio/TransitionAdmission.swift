import Foundation
import OSLog
#if os(iOS)
import os
#endif

/// Why a live smart transition was not admitted. Category only: no titles, paths or byte counts,
/// so it is safe to log and to show.
public enum TransitionAdmissionReason: String, Sendable, Equatable, CaseIterable {
    case unavailableMetadata
    case decodedMemoryBudget
    case memoryPressure
    case thermalPolicy
    case lowPowerPolicy
    case unavailableSource
    /// The incoming track was not prepared before its handoff point.
    case deadline
    /// Fetching, decoding or analysing the incoming track failed.
    case preparationFailed
    case cancelled
    /// Technical details are still being read from the file; retried automatically.
    case preparingDetails
    /// The file's format cannot be decoded for blending.
    case unsupportedFormat
    /// The file could not be read right now; retry later.
    case temporarilyUnreadable

    /// Concise, honest wording for queue / Now Playing surfaces.
    public var message: String {
        switch self {
        case .preparingDetails: "Continuous playback — blend unavailable until track details are read."
        case .unsupportedFormat: "Continuous playback — blend unavailable: unsupported format."
        case .temporarilyUnreadable: "Continuous playback — blend unavailable: audio unreadable, retry later."
        case .decodedMemoryBudget, .memoryPressure:
            "Continuous playback — blend unavailable: not enough safe memory on this device."
        default: "Continuous playback — blend unavailable on this device."
        }
    }

    /// Spoken label: the result and the reason category.
    public var accessibilityLabel: String {
        switch self {
        case .unavailableMetadata: return "Continuous playback. Blend unavailable: track details not known yet."
        case .decodedMemoryBudget: return "Continuous playback. Blend unavailable: track too large to blend on this device."
        case .memoryPressure: return "Continuous playback. Blend unavailable: device memory is low."
        case .thermalPolicy: return "Continuous playback. Blend unavailable: device is warm."
        case .lowPowerPolicy: return "Continuous playback. Blend unavailable: Low Power Mode."
        case .unavailableSource: return "Continuous playback. Blend unavailable: audio source not available."
        case .deadline: return "Continuous playback. Blend unavailable: next track was not ready in time."
        case .preparationFailed: return "Continuous playback. Blend unavailable: could not prepare the next track."
        case .cancelled: return "Continuous playback. Blend cancelled."
        case .preparingDetails: return "Continuous playback. Blend unavailable: reading track details."
        case .unsupportedFormat: return "Continuous playback. Blend unavailable: unsupported format."
        case .temporarilyUnreadable: return "Continuous playback. Blend unavailable: audio unreadable, retry later."
        }
    }
}

public enum TransitionAdmissionDecision: Sendable, Equatable {
    case allowLiveMix
    case allowSafeCrossfade
    case gaplessFallback(reason: TransitionAdmissionReason)
    case `defer`(reason: TransitionAdmissionReason)

    public var allowsWholeTrackMixing: Bool { self == .allowLiveMix }
    public var reason: TransitionAdmissionReason? {
        switch self {
        case .gaplessFallback(let reason), .defer(let reason): return reason
        default: return nil
        }
    }
}

/// What is known about a track without decoding it.
public struct TransitionTrackMetadata: Sendable, Equatable {
    public var durationSec: Double?
    public var sampleRate: Int?
    public var channels: Int?
    public init(durationSec: Double?, sampleRate: Int?, channels: Int? = 2) {
        self.durationSec = durationSec
        self.sampleRate = sampleRate
        self.channels = channels
    }
    /// Bounds are only trusted when duration, rate and channels are all valid.
    var isValid: Bool {
        guard let durationSec, durationSec > 0, durationSec.isFinite, durationSec < 86_400,
              let sampleRate, (8_000...768_000).contains(sampleRate),
              let channels, (1...8).contains(channels) else { return false }
        return true
    }
}

public enum TransitionThermalLevel: Int, Sendable, Equatable { case nominal, fair, serious, critical }

/// Injectable snapshot of the process / device state the decision depends on.
public struct TransitionSystemState: Sendable, Equatable {
    public var availableBytes: Int64?
    public var thermal: TransitionThermalLevel
    public var lowPowerMode: Bool
    public var memoryWarningActive: Bool
    public init(availableBytes: Int64?, thermal: TransitionThermalLevel = .nominal,
                lowPowerMode: Bool = false, memoryWarningActive: Bool = false) {
        self.availableBytes = availableBytes
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
        self.memoryWarningActive = memoryWarningActive
    }

    public static func current() -> TransitionSystemState {
        let thermal: TransitionThermalLevel
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .serious
        }
        #if os(iOS)
        let available: Int64? = Int64(os_proc_available_memory())
        #else
        let available: Int64? = nil
        #endif
        return TransitionSystemState(availableBytes: available, thermal: thermal,
                                     lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                     memoryWarningActive: TransitionPressure.shared.isActive)
    }
}

/// Remembers a recent memory warning so edges decided afterwards fall back safely.
public final class TransitionPressure: @unchecked Sendable {
    public static let shared = TransitionPressure()
    public static let windowSeconds: TimeInterval = 60
    private let lock = NSLock()
    private var last: Date?
    public init() {}
    public func noteMemoryWarning(at date: Date = Date()) { lock.withLock { last = date } }
    public var isActive: Bool {
        lock.withLock { last.map { Date().timeIntervalSince($0) < Self.windowSeconds } ?? false }
    }
}

/// Named limits for the live guard. Defaults favour uninterrupted playback over a blend.
public struct TransitionAdmissionConfig: Sendable, Equatable {
    /// Largest whole-transition peak ever admitted, whatever the device has free.
    public var absoluteCapBytes: Int64 = 768 * 1_024 * 1_024
    /// Fixed allowance on top of the estimate (engine, UI, allocator slack).
    public var safetyReserveBytes: Int64 = 96 * 1_024 * 1_024
    /// Memory that must remain allocatable after the estimated peak.
    public var requiredHeadroomBytes: Int64 = 256 * 1_024 * 1_024
    /// Float samples at the mix decks' rate.
    public var mixSampleRate: Double = 44_100
    public init() {}
    public static let standard = TransitionAdmissionConfig()
}

/// The single authority on whether a live transition (or a lone whole-track decode) may run.
/// Pure: all inputs are injected, so preview and live return the same answer for the same inputs.
public enum TransitionAdmissionController {
    private static let log = Logger(subsystem: "guru.parso.tonearm", category: "TransitionAdmission")

    /// Float PCM of the track at the mix rate, stereo.
    static func mixedBytes(_ m: TransitionTrackMetadata, _ config: TransitionAdmissionConfig) -> Double {
        (m.durationSec ?? 0) * config.mixSampleRate * 2 * 4
    }

    /// Decoding the track: source-rate Int32 + float copies and analyser working buffers (2.5×),
    /// plus a resampled copy when the rate differs, plus the retained tempo-render copy.
    static func incomingBytes(_ m: TransitionTrackMetadata, _ config: TransitionAdmissionConfig) -> Double {
        let rate = Double(m.sampleRate ?? 0)
        let source = (m.durationSec ?? 0) * rate * Double(m.channels ?? 2) * 4 * 2.5
        let resampled = abs(rate - config.mixSampleRate) >= 0.5 ? mixedBytes(m, config) : 0
        return source + resampled + mixedBytes(m, config)
    }

    /// Peak bytes for the whole live transition: retained outgoing buffers, the incoming deck's
    /// decode/resample/tempo copies, and the fixed reserve. Nil when metadata cannot bound it.
    public static func estimatedPeakBytes(outgoing: TransitionTrackMetadata?, incoming: TransitionTrackMetadata,
                                          config: TransitionAdmissionConfig = .standard) -> Int64? {
        guard incoming.isValid else { return nil }
        var total = incomingBytes(incoming, config)
        if let outgoing {
            guard outgoing.isValid else { return nil }
            total += mixedBytes(outgoing, config)
        }
        return Int64(total.rounded(.up)) + config.safetyReserveBytes
    }

    public static func decide(outgoing: TransitionTrackMetadata?, incoming: TransitionTrackMetadata?,
                              sourceAvailable: Bool = true, system: TransitionSystemState,
                              config: TransitionAdmissionConfig = .standard,
                              isCancelled: Bool = false) -> TransitionAdmissionDecision {
        let decision = evaluate(outgoing: outgoing, incoming: incoming, sourceAvailable: sourceAvailable,
                                system: system, config: config, isCancelled: isCancelled)
        let peak = incoming.flatMap { estimatedPeakBytes(outgoing: outgoing, incoming: $0, config: config) } ?? -1
        log.notice("admission \(String(describing: decision), privacy: .public) estimatedPeakMB=\(peak / 1_048_576, privacy: .public)")
        return decision
    }

    private static func evaluate(outgoing: TransitionTrackMetadata?, incoming: TransitionTrackMetadata?,
                                 sourceAvailable: Bool, system: TransitionSystemState,
                                 config: TransitionAdmissionConfig, isCancelled: Bool) -> TransitionAdmissionDecision {
        if isCancelled { return .defer(reason: .cancelled) }
        guard sourceAvailable else { return .gaplessFallback(reason: .unavailableSource) }
        if system.thermal.rawValue >= TransitionThermalLevel.serious.rawValue { return .gaplessFallback(reason: .thermalPolicy) }
        if system.lowPowerMode { return .gaplessFallback(reason: .lowPowerPolicy) }
        if system.memoryWarningActive { return .defer(reason: .memoryPressure) }
        guard let incoming, let peak = estimatedPeakBytes(outgoing: outgoing, incoming: incoming, config: config) else {
            return .gaplessFallback(reason: .unavailableMetadata)
        }
        if peak > config.absoluteCapBytes { return .gaplessFallback(reason: .decodedMemoryBudget) }
        if let available = system.availableBytes, peak + config.requiredHeadroomBytes > available {
            return .gaplessFallback(reason: .memoryPressure)
        }
        return .allowLiveMix
    }
}

/// What the audio path actually did at an edge, as opposed to the style that was requested or
/// the preparation result. Surfaces must label the edge from this, never from a promised style.
public enum TransitionExecutedKind: String, Sendable, Equatable, CaseIterable {
    /// Both sources were audible together.
    case overlapCrossfade
    /// The outgoing track faded out, then the incoming faded in; sources never overlapped.
    case fadeOutFadeIn
    /// One track ended and the next started; continuity is not proven.
    case sequentialHandoff
    /// Continuity was proven (e.g. same-album, sample-accurate follow-on).
    case gapless

    public static func resolve(sourcesOverlap: Bool, fades: Bool, continuityProven: Bool) -> TransitionExecutedKind {
        if sourcesOverlap { return .overlapCrossfade }
        if fades { return .fadeOutFadeIn }
        return continuityProven ? .gapless : .sequentialHandoff
    }

    public var label: String {
        switch self {
        case .overlapCrossfade: "Crossfade"
        case .fadeOutFadeIn: "Fade out, fade in"
        case .sequentialHandoff: "Sequential handoff"
        case .gapless: "Gapless"
        }
    }
}

/// The honest state of an edge that is not blending, published for queue / Now Playing surfaces.
public struct TransitionFallbackStatus: Sendable, Equatable {
    public let reason: TransitionAdmissionReason
    public let isDeferred: Bool
    /// A denied edge plays through the normal player: sequential, never labelled gapless or crossfade.
    public let executed: TransitionExecutedKind = .sequentialHandoff
    public init(decision: TransitionAdmissionDecision) {
        reason = decision.reason ?? .unavailableMetadata
        if case .defer = decision { isDeferred = true } else { isDeferred = false }
    }
    public var message: String { reason.message }
    public var accessibilityLabel: String { reason.accessibilityLabel }
}

/// Runs full-track decodes one at a time across the whole app. A queued decode that was
/// cancelled before its turn never starts, and the next one waits until the previous has fully
/// finished (released its buffers).
public actor TransitionDecodeGate {
    public static let shared = TransitionDecodeGate()
    private var tail: Task<Void, Never>?

    public init() {}

    public func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await runAsync { try operation() }
    }

    public func runAsync<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let work = Task.detached(priority: .utility) { () throws -> T in
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
