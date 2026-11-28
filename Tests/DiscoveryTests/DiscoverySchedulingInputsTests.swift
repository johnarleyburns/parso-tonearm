import Foundation
import Testing

@testable import TonearmDiscovery

/// The raw-platform-inputs → `DiscoverySchedulingSnapshot` mapping
/// (IMPLEMENT_CLAP_PLAN.md §6: battery/thermal/power must be REAL, never
/// fabricated — an unreadable value is *unknown*, never assumed healthy).
@Suite struct DiscoverySchedulingInputsTests {
    private func inputs(
        thermalState: DiscoveryThermalState = .nominal,
        rawBatteryLevel: Double = 0.8,
        isCharging: Bool = false,
        nominalSince: Date? = nil,
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) -> DiscoveryRawSchedulingInputs {
        DiscoveryRawSchedulingInputs(
            appState: .foreground,
            thermalState: thermalState,
            rawBatteryLevel: rawBatteryLevel,
            isCharging: isCharging,
            isLowPowerModeEnabled: false,
            isPlaybackActive: false,
            isUserPaused: false,
            chargingOnlySetting: false,
            hasBackgroundProcessingGrant: false,
            hasMemoryWarning: false,
            nominalSince: nominalSince,
            now: now)
    }

    @Test func testUnreadableBatteryBecomesNilNotHealthy() {
        let snap = DiscoverySchedulingSnapshot.from(inputs(rawBatteryLevel: -1))
        #expect(snap.batteryLevel == nil)
    }

    @Test func testNonFiniteBatteryBecomesNil() {
        let snap = DiscoverySchedulingSnapshot.from(inputs(rawBatteryLevel: .nan))
        #expect(snap.batteryLevel == nil)
    }

    @Test func testReadableBatteryPassesThroughClamped() {
        #expect(DiscoverySchedulingSnapshot.from(inputs(rawBatteryLevel: 0.42)).batteryLevel == 0.42)
        #expect(DiscoverySchedulingSnapshot.from(inputs(rawBatteryLevel: 1.5)).batteryLevel == 1.0)
    }

    @Test func testContinuousNominalSecondsDerivedFromTimestamp() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snap = DiscoverySchedulingSnapshot.from(
            inputs(thermalState: .nominal, nominalSince: now.addingTimeInterval(-75), now: now))
        #expect(abs(snap.continuousNominalSeconds - 75) <= 0.001)
    }

    @Test func testContinuousNominalSecondsIsZeroWhenNotNominal() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snap = DiscoverySchedulingSnapshot.from(
            inputs(thermalState: .fair, nominalSince: nil, now: now))
        #expect(snap.continuousNominalSeconds == 0)
    }

    @Test func testContinuousNominalSecondsIsZeroWithNoTimestampEvenIfNominal() {
        let snap = DiscoverySchedulingSnapshot.from(inputs(thermalState: .nominal, nominalSince: nil))
        #expect(snap.continuousNominalSeconds == 0)
    }

    /// End-to-end: a freshly-charging device with a cool thermal history is
    /// allowed to index; an unknown battery while unplugged is not (plan §6).
    @Test func testMappedSnapshotDrivesPolicyConsistently() {
        let now = Date(timeIntervalSince1970: 10_000)
        let ok = DiscoverySchedulingSnapshot.from(
            inputs(rawBatteryLevel: 0.9, isCharging: true,
                   nominalSince: now.addingTimeInterval(-120), now: now))
        #expect(IndexPolicy.decide(ok) == .proceed)

        let unknownUnplugged = DiscoverySchedulingSnapshot.from(
            inputs(rawBatteryLevel: -1, isCharging: false,
                   nominalSince: now.addingTimeInterval(-120), now: now))
        #expect(IndexPolicy.decide(unknownUnplugged)
                       == .blocked(reason: .lowBatteryOrLowPowerMode))
    }
}
