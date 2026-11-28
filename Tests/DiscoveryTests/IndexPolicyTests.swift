import Foundation
import Testing

@testable import TonearmDiscovery

/// Deterministic policy-gate fixtures (IMPLEMENT_CLAP_PLAN.md §6/§11 C05):
/// every case is pure input -> decision, no clock/device access, matching
/// "Do not require iOS to grant a real task to pass deterministic tests."
@Suite struct IndexPolicyTests {
    private func snapshot(
        appState: DiscoveryAppRunState = .foreground,
        thermalState: DiscoveryThermalState = .nominal,
        batteryLevel: Double? = 0.8,
        isCharging: Bool = false,
        isLowPowerModeEnabled: Bool = false,
        isPlaybackActive: Bool = false,
        isUserPaused: Bool = false,
        chargingOnlySetting: Bool = false,
        hasBackgroundProcessingGrant: Bool = false,
        hasMemoryWarning: Bool = false,
        isUserSelectedTrackRequest: Bool = false,
        continuousNominalSeconds: TimeInterval = 120,
        isCurrentJobRemoteSparse: Bool = false,
        remoteIndexingWiFiOnlySetting: Bool = true,
        isOnWiFi: Bool = true
    ) -> DiscoverySchedulingSnapshot {
        DiscoverySchedulingSnapshot(
            appState: appState,
            thermalState: thermalState,
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            isPlaybackActive: isPlaybackActive,
            isUserPaused: isUserPaused,
            chargingOnlySetting: chargingOnlySetting,
            hasBackgroundProcessingGrant: hasBackgroundProcessingGrant,
            hasMemoryWarning: hasMemoryWarning,
            isUserSelectedTrackRequest: isUserSelectedTrackRequest,
            continuousNominalSeconds: continuousNominalSeconds,
            isCurrentJobRemoteSparse: isCurrentJobRemoteSparse,
            remoteIndexingWiFiOnlySetting: remoteIndexingWiFiOnlySetting,
            isOnWiFi: isOnWiFi)
    }

    @Test func testNominalForegroundProceedsWithTwoSecondDelay() {
        let decision = IndexPolicy.decide(snapshot())
        #expect(decision == .proceed)
    }

    @Test func testUserPauseAlwaysWins() {
        let decision = IndexPolicy.decide(
            snapshot(thermalState: .critical, isUserPaused: true))
        #expect(decision == .blocked(reason: .userPaused))
    }

    @Test func testThermalCriticalIsNeverOverridable() {
        let decision = IndexPolicy.decide(
            snapshot(thermalState: .critical, isUserSelectedTrackRequest: true))
        #expect(decision == .blocked(reason: .thermalCritical))
    }

    @Test func testThermalSeriousIsNeverOverridable() {
        let decision = IndexPolicy.decide(
            snapshot(thermalState: .serious, isUserSelectedTrackRequest: true))
        #expect(decision == .blocked(reason: .thermalSerious))
    }

    /// `.fair` does not halt the scheduler: the BPM/key/energy pass is a short
    /// CPU-only measurement, so a `.fair` reading is no reason to stop it.
    @Test func testThermalFairDoesNotBlockScheduling() {
        let decision = IndexPolicy.decide(
            snapshot(thermalState: .fair, isUserSelectedTrackRequest: true))
        #expect(decision == .proceed)
    }

    @Test func testThermalFairInBackgroundStillProceedsWhileCharging() {
        let decision = IndexPolicy.decide(
            snapshot(appState: .background, thermalState: .fair, isCharging: true,
                     hasBackgroundProcessingGrant: true))
        #expect(decision == .proceed)
    }

    @Test func testMemoryWarningBlocks() {
        let decision = IndexPolicy.decide(snapshot(hasMemoryWarning: true))
        #expect(decision == .blocked(reason: .memoryWarning))
    }

    /// Real user feedback: listening while the library builds its sound index is a main use
    /// case — automatic indexing must keep running during playback, not pause for it (see
    /// `IndexPolicy.decide`'s `.foreground` case doc for the full reasoning/history).
    @Test func testPlaybackActiveDoesNotBlockAutomaticIndexing() {
        let decision = IndexPolicy.decide(snapshot(isPlaybackActive: true))
        #expect(decision == .proceed)
    }

    @Test func testLowPowerModeUnpluggedBlocksAutomaticButSelectedTrackOverrides() {
        let blocked = IndexPolicy.decide(
            snapshot(isCharging: false, isLowPowerModeEnabled: true))
        #expect(blocked == .blocked(reason: .lowBatteryOrLowPowerMode))

        let overridden = IndexPolicy.decide(
            snapshot(
                isCharging: false, isLowPowerModeEnabled: true,
                isUserSelectedTrackRequest: true))
        #expect(overridden == .proceed)
    }

    @Test func testLowBatteryUnderThresholdUnpluggedBlocks() {
        let decision = IndexPolicy.decide(
            snapshot(batteryLevel: 0.29, isCharging: false))
        #expect(decision == .blocked(reason: .lowBatteryOrLowPowerMode))
    }

    @Test func testUnknownBatteryUnpluggedIsTreatedAsLow() {
        let decision = IndexPolicy.decide(snapshot(batteryLevel: nil, isCharging: false))
        #expect(decision == .blocked(reason: .lowBatteryOrLowPowerMode))
    }

    @Test func testLowBatteryWhileChargingProceeds() {
        let decision = IndexPolicy.decide(snapshot(batteryLevel: 0.1, isCharging: true))
        #expect(decision == .proceed)
    }

    @Test func testChargingOnlySettingBlocksWhenUnplugged() {
        let decision = IndexPolicy.decide(
            snapshot(isCharging: false, chargingOnlySetting: true))
        #expect(decision == .blocked(reason: .chargingOnlyRequired))
    }

    @Test func testChargingOnlySettingProceedsWhenCharging() {
        let decision = IndexPolicy.decide(
            snapshot(isCharging: true, chargingOnlySetting: true))
        #expect(decision == .proceed)
    }

    @Test func testRemoteSparseJobBlocksOffWiFiWhenWiFiOnlySettingIsOn() {
        let decision = IndexPolicy.decide(
            snapshot(
                isCurrentJobRemoteSparse: true, remoteIndexingWiFiOnlySetting: true,
                isOnWiFi: false))
        #expect(decision == .blocked(reason: .remoteSamplingRequiresWiFi))
    }

    @Test func testRemoteSparseJobProceedsOnWiFi() {
        let decision = IndexPolicy.decide(
            snapshot(
                isCurrentJobRemoteSparse: true, remoteIndexingWiFiOnlySetting: true,
                isOnWiFi: true))
        #expect(decision == .proceed)
    }

    @Test func testRemoteSparseJobProceedsOffWiFiWhenWiFiOnlySettingIsOff() {
        let decision = IndexPolicy.decide(
            snapshot(
                isCurrentJobRemoteSparse: true, remoteIndexingWiFiOnlySetting: false,
                isOnWiFi: false))
        #expect(decision == .proceed)
    }

    @Test func testLocalJobNeverBlockedByWiFiGateRegardlessOfNetwork() {
        let decision = IndexPolicy.decide(
            snapshot(
                isCurrentJobRemoteSparse: false, remoteIndexingWiFiOnlySetting: true,
                isOnWiFi: false))
        #expect(decision == .proceed)
    }

    @Test func testBackgroundWithoutGrantBlocks() {
        let decision = IndexPolicy.decide(
            snapshot(
                appState: .background, isCharging: true,
                hasBackgroundProcessingGrant: false))
        #expect(decision == .blocked(reason: .backgroundGrantMissing))
    }

    @Test func testBackgroundRequiresChargingRegardlessOfChargingOnlySetting() {
        let decision = IndexPolicy.decide(
            snapshot(
                appState: .background, isCharging: false,
                hasBackgroundProcessingGrant: true))
        #expect(decision == .blocked(reason: .chargingOnlyRequired))
    }

    @Test func testBackgroundGrantedAndChargingProceedsWithZeroInterWindowDelay() {
        let decision = IndexPolicy.decide(
            snapshot(
                appState: .background, isCharging: true,
                hasBackgroundProcessingGrant: true))
        #expect(decision == .proceed)
    }

    // MARK: - ThermalDiagnostic

    @Test func testThermalDiagnosticCountsDownWhileNominal() {
        let d = ThermalDiagnostic(state: .nominal, continuousNominalSeconds: 37)
        #expect(abs(d.secondsUntilRecovered - 23) <= 0.001)
    }

    @Test func testThermalDiagnosticClampsAtZeroOnceRecovered() {
        let d = ThermalDiagnostic(state: .nominal, continuousNominalSeconds: 90)
        #expect(d.secondsUntilRecovered == 0)
    }

    /// A currently non-nominal state has nothing to "count down" — the full window is still
    /// required from the moment it returns to `.nominal`.
    @Test func testThermalDiagnosticReportsFullWindowWhileNotNominal() {
        let d = ThermalDiagnostic(state: .fair, continuousNominalSeconds: 0)
        #expect(d.secondsUntilRecovered == IndexPolicy.thermalFairRecoverySeconds)
    }
}
