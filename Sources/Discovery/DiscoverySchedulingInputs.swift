import Foundation

/// Raw, platform-sourced values gathered by the iOS adapter
/// (`DiscoveryRuntimeController`) before they are normalised into a
/// `DiscoverySchedulingSnapshot`. Kept in the portable `TonearmDiscovery`
/// target — with no UIKit/ProcessInfo access of its own — so the
/// raw-inputs → snapshot mapping is unit-testable without a device
/// (plan §6: battery/thermal/power must be REAL, never fabricated; §11 C05:
/// "Do not require iOS to grant a real task to pass deterministic tests").
public struct DiscoveryRawSchedulingInputs: Equatable, Sendable {
    public var appState: DiscoveryAppRunState
    public var thermalState: DiscoveryThermalState
    /// Exactly what `UIDevice.current.batteryLevel` returned: `-1` when the
    /// platform cannot report it, otherwise `0...1`.
    public var rawBatteryLevel: Double
    public var isCharging: Bool
    public var isLowPowerModeEnabled: Bool
    public var isPlaybackActive: Bool
    public var isUserPaused: Bool
    public var chargingOnlySetting: Bool
    public var hasBackgroundProcessingGrant: Bool
    public var hasMemoryWarning: Bool
    public var isUserSelectedTrackRequest: Bool
    /// The instant thermal state last became `.nominal` (`nil` while it is not
    /// nominal). The mapping derives `continuousNominalSeconds` from this and
    /// `now`, so the caller only has to remember one timestamp.
    public var nominalSince: Date?
    public var now: Date

    public init(
        appState: DiscoveryAppRunState,
        thermalState: DiscoveryThermalState,
        rawBatteryLevel: Double,
        isCharging: Bool,
        isLowPowerModeEnabled: Bool,
        isPlaybackActive: Bool,
        isUserPaused: Bool,
        chargingOnlySetting: Bool,
        hasBackgroundProcessingGrant: Bool,
        hasMemoryWarning: Bool,
        isUserSelectedTrackRequest: Bool = false,
        nominalSince: Date? = nil,
        now: Date = Date()
    ) {
        self.appState = appState
        self.thermalState = thermalState
        self.rawBatteryLevel = rawBatteryLevel
        self.isCharging = isCharging
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.isPlaybackActive = isPlaybackActive
        self.isUserPaused = isUserPaused
        self.chargingOnlySetting = chargingOnlySetting
        self.hasBackgroundProcessingGrant = hasBackgroundProcessingGrant
        self.hasMemoryWarning = hasMemoryWarning
        self.isUserSelectedTrackRequest = isUserSelectedTrackRequest
        self.nominalSince = nominalSince
        self.now = now
    }
}

extension DiscoverySchedulingSnapshot {
    /// Normalise raw platform inputs into the policy snapshot. The only
    /// transformations: an unreadable battery level (`< 0`) becomes `nil`
    /// (unknown — never assumed healthy, plan §6), and
    /// `continuousNominalSeconds` is derived from `nominalSince`.
    public static func from(_ i: DiscoveryRawSchedulingInputs) -> DiscoverySchedulingSnapshot {
        let battery: Double?
        if i.rawBatteryLevel < 0 || !i.rawBatteryLevel.isFinite {
            battery = nil
        } else {
            battery = min(1, i.rawBatteryLevel)
        }

        let nominalSeconds: TimeInterval
        if i.thermalState == .nominal, let since = i.nominalSince {
            nominalSeconds = max(0, i.now.timeIntervalSince(since))
        } else {
            nominalSeconds = 0
        }

        return DiscoverySchedulingSnapshot(
            appState: i.appState,
            thermalState: i.thermalState,
            batteryLevel: battery,
            isCharging: i.isCharging,
            isLowPowerModeEnabled: i.isLowPowerModeEnabled,
            isPlaybackActive: i.isPlaybackActive,
            isUserPaused: i.isUserPaused,
            chargingOnlySetting: i.chargingOnlySetting,
            hasBackgroundProcessingGrant: i.hasBackgroundProcessingGrant,
            hasMemoryWarning: i.hasMemoryWarning,
            isUserSelectedTrackRequest: i.isUserSelectedTrackRequest,
            continuousNominalSeconds: nominalSeconds)
    }
}
