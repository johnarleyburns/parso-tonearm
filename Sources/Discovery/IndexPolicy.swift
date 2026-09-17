import Foundation

/// Deterministic scheduling-gate policy (plan §6 table). Pure function of an
/// injected snapshot — no clock/notification/UIKit access here, so it is
/// unit-testable without a device (plan §11 C05: "Do not require iOS to
/// grant a real task to pass deterministic tests").
///
/// This governs whether the scheduler is allowed to CLAIM/CONTINUE work at
/// all. It intentionally does NOT persist a `DiscoveryJobState` for most
/// blocks (plan §4: "Global user pause is a persisted scheduling gate, not
/// thousands of per-track mutations") — only the two conditions the plan's
/// own job-state enum has room for (`waitingForPower`, `waitingForCooling`)
/// are ever written onto a job already mid-flight; every other gate here is
/// scheduler-level (nothing claimed, nothing to mark).
public enum DiscoveryAppRunState: Equatable, Sendable {
    case foreground
    case background
}

public enum DiscoveryThermalState: Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

/// Everything the policy needs to decide, gathered by the caller (iOS
/// adapter in production, a fake in tests). No field is read from a live
/// system API inside this type.
public struct DiscoverySchedulingSnapshot: Equatable, Sendable {
    public var appState: DiscoveryAppRunState
    public var thermalState: DiscoveryThermalState
    /// 0...1, nil when the platform cannot report it (treated as unknown/low,
    /// never assumed healthy — plan §6: "Do not use fake battery values").
    public var batteryLevel: Double?
    public var isCharging: Bool
    public var isLowPowerModeEnabled: Bool
    public var isPlaybackActive: Bool
    public var isUserPaused: Bool
    public var chargingOnlySetting: Bool
    public var hasBackgroundProcessingGrant: Bool
    public var hasMemoryWarning: Bool
    /// True only for a single, explicit user "analyze this track now" request
    /// in the foreground (plan §6: "A user may request one selected track in
    /// foreground; never override serious/critical thermal gates").
    public var isUserSelectedTrackRequest: Bool
    /// Seconds the thermal state has continuously read `.nominal`, tracked by
    /// the caller (IndexScheduler) across ticks so this type stays pure
    /// (plan §6: "Thermal fair: ... wait until nominal continuously for 60
    /// seconds").
    public var continuousNominalSeconds: TimeInterval

    public init(
        appState: DiscoveryAppRunState,
        thermalState: DiscoveryThermalState,
        batteryLevel: Double?,
        isCharging: Bool,
        isLowPowerModeEnabled: Bool,
        isPlaybackActive: Bool,
        isUserPaused: Bool,
        chargingOnlySetting: Bool,
        hasBackgroundProcessingGrant: Bool,
        hasMemoryWarning: Bool,
        isUserSelectedTrackRequest: Bool = false,
        continuousNominalSeconds: TimeInterval = 0
    ) {
        self.appState = appState
        self.thermalState = thermalState
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.isPlaybackActive = isPlaybackActive
        self.isUserPaused = isUserPaused
        self.chargingOnlySetting = chargingOnlySetting
        self.hasBackgroundProcessingGrant = hasBackgroundProcessingGrant
        self.hasMemoryWarning = hasMemoryWarning
        self.isUserSelectedTrackRequest = isUserSelectedTrackRequest
        self.continuousNominalSeconds = continuousNominalSeconds
    }
}

/// Real numbers behind a `.thermalFair`/`.thermalSerious`/`.thermalCritical` block, captured at
/// the moment the scheduler recorded it — never fabricated (CLAUDE.md "no silent/magic background
/// work"). `.fair`'s recovery rule requires `continuousNominalSeconds` to reach
/// `IndexPolicy.thermalFairRecoverySeconds` while `state` has already returned to `.nominal`; that
/// distinction matters because a device reporting `.nominal` right now, mid-countdown, reads very
/// differently to a user than one currently reporting `.fair`/`.serious`/`.critical` — collapsing
/// both into one "cool down" message is exactly the illegible state CLAUDE.md forbids.
public struct ThermalDiagnostic: Equatable, Sendable {
    public var state: DiscoveryThermalState
    public var continuousNominalSeconds: TimeInterval

    public init(state: DiscoveryThermalState, continuousNominalSeconds: TimeInterval) {
        self.state = state
        self.continuousNominalSeconds = continuousNominalSeconds
    }

    /// Seconds still needed of continuous `.nominal` before the `.fair` recovery rule clears;
    /// `0` once satisfied or when `state` is not `.nominal` (nothing to count down from).
    public var secondsUntilRecovered: TimeInterval {
        guard state == .nominal else { return IndexPolicy.thermalFairRecoverySeconds }
        return max(0, IndexPolicy.thermalFairRecoverySeconds - continuousNominalSeconds)
    }
}

public enum IndexBlockReason: Equatable, Sendable {
    case userPaused
    case playbackActive
    case thermalFair
    case thermalSerious
    case thermalCritical
    case memoryWarning
    case lowBatteryOrLowPowerMode
    case chargingOnlyRequired
    case backgroundGrantMissing
}

public enum IndexPolicyDecision: Equatable, Sendable {
    /// Allowed to claim/continue work, waiting this long between windows.
    case proceed(interWindowDelaySeconds: TimeInterval)
    case blocked(reason: IndexBlockReason)
}

public enum IndexPolicy {
    public static let foregroundInterWindowDelaySeconds: TimeInterval = 2
    public static let thermalFairRecoverySeconds: TimeInterval = 60
    public static let lowBatteryThreshold: Double = 0.30
    public static let foregroundRunLimitSeconds: TimeInterval = 120
    public static let foregroundCooldownSeconds: TimeInterval = 30

    public static func decide(_ s: DiscoverySchedulingSnapshot) -> IndexPolicyDecision {
        if s.isUserPaused { return .blocked(reason: .userPaused) }

        // Thermal serious/critical and memory warnings are never overridable
        // (plan §6: "never override serious/critical thermal gates").
        if s.thermalState == .critical { return .blocked(reason: .thermalCritical) }
        if s.thermalState == .serious { return .blocked(reason: .thermalSerious) }
        if s.hasMemoryWarning { return .blocked(reason: .memoryWarning) }
        if s.thermalState == .fair || s.continuousNominalSeconds < thermalFairRecoverySeconds {
            return .blocked(reason: .thermalFair)
        }

        switch s.appState {
        case .background:
            guard s.hasBackgroundProcessingGrant else {
                return .blocked(reason: .backgroundGrantMissing)
            }
            // Background indexing requires external power regardless of the
            // charging-only user setting (plan §7:
            // "requiresExternalPower=true ... for the local indexing task").
            guard s.isCharging else { return .blocked(reason: .chargingOnlyRequired) }
            return .proceed(interWindowDelaySeconds: 0)

        case .foreground:
            // Deliberately does NOT block on `s.isPlaybackActive`. The original plan paused
            // automatic indexing during playback (IMPLEMENT_CLAP_PLAN.md §6: "Pause automatic
            // audio analysis to prioritize listening"), reasoning that decode+CLAP inference
            // competing with the real-time audio render thread risked glitches. Real user
            // feedback: listening while the library builds its sound index is a main use case,
            // not an edge case — indexing must keep running while a track plays. `.background`
            // execution context (CPU-only, no GPU/ANE — see `DiscoveryRuntimeController`) is
            // lighter-weight than the old GPU/ANE path this rule was originally written against,
            // which reduces (does not guarantee zero) contention risk with the playback thread.
            // `IndexBlockReason.playbackActive` and `isUserSelectedTrackRequest`'s bypass of it
            // are kept (tests, exhaustive switches) in case this needs to be revisited.

            let batteryLow = s.isLowPowerModeEnabled || (s.batteryLevel ?? 0) < lowBatteryThreshold
            if batteryLow && !s.isCharging {
                if s.isUserSelectedTrackRequest {
                    return .proceed(interWindowDelaySeconds: foregroundInterWindowDelaySeconds)
                }
                return .blocked(reason: .lowBatteryOrLowPowerMode)
            }

            if s.chargingOnlySetting && !s.isCharging {
                return .blocked(reason: .chargingOnlyRequired)
            }

            return .proceed(interWindowDelaySeconds: foregroundInterWindowDelaySeconds)
        }
    }
}
