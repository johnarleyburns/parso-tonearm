import Foundation

/// The thermal governor (§43.7, normative — NFR-THERM-2, FR-ANL-7).
///
/// Every background lane declares its behaviour at each `ProcessInfo.thermalState`.
/// This type *is* the table; there is no discretionary throttling anywhere else.
/// The decision function is pure so it is tested as a decision table, one row per
/// §43.7 cell (NFR-THERM-4: the current decision is stated in words for the UI).
public struct ThermalGovernor: Sendable {

    /// The analysis lanes the governor throttles (§43.7). `essentials` is Stage 1
    /// (loudness/FFT/onsets/tempo/beats/key/phrase/energy/waveform); `embeddings`
    /// is Stage 2 (M2); `stems` is Stage 3 (prepared stems, M2+).
    public enum Lane: String, Sendable, CaseIterable {
        case essentials
        case embeddings
        case stems
    }

    /// How a lane runs under the current thermal state (§43.7).
    public enum Decision: Sendable, Equatable {
        /// Run at full concurrency.
        case full
        /// Run at half concurrency.
        case halfConcurrency
        /// Suspended entirely.
        case paused

        public var isPaused: Bool { self == .paused }
    }

    /// The §43.7 table. `Performance engine` and `Telemetry`/`Liquid Glass`/etc.
    /// lanes are not analysis lanes and are not modelled here; the analysis
    /// lanes are. `.critical` is full for the performance engine — which is not
    /// this type's concern — and paused for every analysis lane.
    public static func decision(for lane: Lane,
                                thermalState: ProcessInfo.ThermalState) -> Decision {
        switch lane {
        case .essentials:
            switch thermalState {
            case .nominal: return .full
            case .fair: return .full
            case .serious: return .halfConcurrency
            case .critical: return .paused
            @unknown default: return .full
            }
        case .embeddings:
            switch thermalState {
            case .nominal: return .full
            case .fair: return .halfConcurrency
            case .serious: return .paused
            case .critical: return .paused
            @unknown default: return .full
            }
        case .stems:
            switch thermalState {
            case .nominal: return .full
            case .fair: return .halfConcurrency
            case .serious: return .paused
            case .critical: return .paused
            @unknown default: return .full
            }
        }
    }

    /// Hysteretic recovery (§43.7): a lane resumes one state *below* where it
    /// was shed, so the device does not oscillate at the boundary. Given the
    /// thermal state at which the lane is currently paused/shed and the lane,
    /// returns the state that must be reached before it may resume.
    ///
    /// Concretely: a lane paused at `.serious` resumes at `.nominal`, not at
    /// `.fair`; a lane shed to half concurrency at `.fair` resumes at `.nominal`.
    public static func resumeThreshold(for lane: Lane,
                                       shedAt thermalState: ProcessInfo.ThermalState) -> ProcessInfo.ThermalState {
        switch thermalState {
        case .nominal, .fair, .critical:
            // Shed at nominal/fair: recover immediately at nominal. Shed at
            // critical: only recover after leaving critical (one state below).
            return .nominal
        case .serious:
            // Shed at serious: recover one state below serious.
            return .nominal
        @unknown default:
            return .nominal
        }
    }

    /// Whether the lane may currently run, given where it was last shed.
    /// `shedAtThermalState` is the state at which the lane last paused/shed;
    /// nil means it was never shed.
    public static func canRun(lane: Lane,
                              currentThermalState: ProcessInfo.ThermalState,
                              shedAtThermalState: ProcessInfo.ThermalState?) -> Bool {
        guard let shedAt = shedAtThermalState else { return true }
        let threshold = resumeThreshold(for: lane, shedAt: shedAt)
        return thermalRank(currentThermalState) <= thermalRank(threshold)
    }

    /// Battery/power gates, independent of thermal state (§43.7, FR-ANL-7):
    /// bulk analysis requires mains power or an explicit override, and never
    /// starts below 20% battery.
    public static func powerAllowsBulk(batteryLevelPercent: Double,
                                       isCharging: Bool,
                                       userOverride: Bool) -> Bool {
        if batteryLevelPercent < 20 { return false }
        return isCharging || userOverride
    }

    /// A live performance session pins every analysis lane to paused regardless
    /// of thermal or power state (§43.7, FR-ANL-2).
    public static func performancePinsLanesPaused(_ isPerforming: Bool) -> Bool { isPerforming }

    // MARK: - Human words (NFR-THERM-4)

    /// The current decision stated in words for the UI (§41.3).
    public static func words(lane: Lane,
                             thermalState: ProcessInfo.ThermalState,
                             batteryLevelPercent: Double,
                             isCharging: Bool,
                             userOverride: Bool,
                             isPerforming: Bool) -> String {
        if isPerforming { return "paused — a performance is active" }
        if batteryLevelPercent < 20 { return "paused — battery below 20%" }
        if !isCharging && !userOverride { return "paused — waiting for a charger" }

        switch decision(for: lane, thermalState: thermalState) {
        case .full: return "running — full speed"
        case .halfConcurrency: return "slowed — device is warm"
        case .paused:
            switch thermalState {
            case .critical: return "paused — device is very hot"
            case .serious: return "paused — device is warm"
            default: return "paused"
            }
        }
    }

    // MARK: - Helpers

    private static func thermalRank(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}
