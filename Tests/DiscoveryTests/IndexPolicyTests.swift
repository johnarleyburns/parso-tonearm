import XCTest

@testable import TonearmDiscovery

/// Deterministic policy-gate fixtures (IMPLEMENT_CLAP_PLAN.md §6/§11 C05):
/// every case is pure input -> decision, no clock/device access, matching
/// "Do not require iOS to grant a real task to pass deterministic tests."
final class IndexPolicyTests: XCTestCase {
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
        continuousNominalSeconds: TimeInterval = 120
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
            continuousNominalSeconds: continuousNominalSeconds)
    }

    func testNominalForegroundProceedsWithTwoSecondDelay() {
        let decision = IndexPolicy.decide(snapshot())
        XCTAssertEqual(decision, .proceed(interWindowDelaySeconds: 2))
    }

    func testUserPauseAlwaysWins() {
        let decision = IndexPolicy.decide(
            snapshot(thermalState: .critical, isUserPaused: true))
        XCTAssertEqual(decision, .blocked(reason: .userPaused))
    }

    func testThermalCriticalIsNeverOverridable() {
        let decision = IndexPolicy.decide(
            snapshot(thermalState: .critical, isUserSelectedTrackRequest: true))
        XCTAssertEqual(decision, .blocked(reason: .thermalCritical))
    }

    func testThermalSeriousIsNeverOverridable() {
        let decision = IndexPolicy.decide(
            snapshot(thermalState: .serious, isUserSelectedTrackRequest: true))
        XCTAssertEqual(decision, .blocked(reason: .thermalSerious))
    }

    func testThermalFairBlocksEvenWithSelectedTrackRequest() {
        let decision = IndexPolicy.decide(
            snapshot(thermalState: .fair, isUserSelectedTrackRequest: true))
        XCTAssertEqual(decision, .blocked(reason: .thermalFair))
    }

    func testThermalFairRecoveryRequiresSixtyContinuousNominalSeconds() {
        let stillBlocked = IndexPolicy.decide(
            snapshot(thermalState: .nominal, continuousNominalSeconds: 59))
        XCTAssertEqual(stillBlocked, .blocked(reason: .thermalFair))

        let recovered = IndexPolicy.decide(
            snapshot(thermalState: .nominal, continuousNominalSeconds: 60))
        XCTAssertEqual(recovered, .proceed(interWindowDelaySeconds: 2))
    }

    func testMemoryWarningBlocks() {
        let decision = IndexPolicy.decide(snapshot(hasMemoryWarning: true))
        XCTAssertEqual(decision, .blocked(reason: .memoryWarning))
    }

    func testPlaybackActiveBlocksAutomaticButSelectedTrackOverrides() {
        let blocked = IndexPolicy.decide(snapshot(isPlaybackActive: true))
        XCTAssertEqual(blocked, .blocked(reason: .playbackActive))

        let overridden = IndexPolicy.decide(
            snapshot(isPlaybackActive: true, isUserSelectedTrackRequest: true))
        XCTAssertEqual(overridden, .proceed(interWindowDelaySeconds: 2))
    }

    func testLowPowerModeUnpluggedBlocksAutomaticButSelectedTrackOverrides() {
        let blocked = IndexPolicy.decide(
            snapshot(isCharging: false, isLowPowerModeEnabled: true))
        XCTAssertEqual(blocked, .blocked(reason: .lowBatteryOrLowPowerMode))

        let overridden = IndexPolicy.decide(
            snapshot(
                isCharging: false, isLowPowerModeEnabled: true,
                isUserSelectedTrackRequest: true))
        XCTAssertEqual(overridden, .proceed(interWindowDelaySeconds: 2))
    }

    func testLowBatteryUnderThresholdUnpluggedBlocks() {
        let decision = IndexPolicy.decide(
            snapshot(batteryLevel: 0.29, isCharging: false))
        XCTAssertEqual(decision, .blocked(reason: .lowBatteryOrLowPowerMode))
    }

    func testUnknownBatteryUnpluggedIsTreatedAsLow() {
        let decision = IndexPolicy.decide(snapshot(batteryLevel: nil, isCharging: false))
        XCTAssertEqual(decision, .blocked(reason: .lowBatteryOrLowPowerMode))
    }

    func testLowBatteryWhileChargingProceeds() {
        let decision = IndexPolicy.decide(snapshot(batteryLevel: 0.1, isCharging: true))
        XCTAssertEqual(decision, .proceed(interWindowDelaySeconds: 2))
    }

    func testChargingOnlySettingBlocksWhenUnplugged() {
        let decision = IndexPolicy.decide(
            snapshot(isCharging: false, chargingOnlySetting: true))
        XCTAssertEqual(decision, .blocked(reason: .chargingOnlyRequired))
    }

    func testChargingOnlySettingProceedsWhenCharging() {
        let decision = IndexPolicy.decide(
            snapshot(isCharging: true, chargingOnlySetting: true))
        XCTAssertEqual(decision, .proceed(interWindowDelaySeconds: 2))
    }

    func testBackgroundWithoutGrantBlocks() {
        let decision = IndexPolicy.decide(
            snapshot(
                appState: .background, isCharging: true,
                hasBackgroundProcessingGrant: false))
        XCTAssertEqual(decision, .blocked(reason: .backgroundGrantMissing))
    }

    func testBackgroundRequiresChargingRegardlessOfChargingOnlySetting() {
        let decision = IndexPolicy.decide(
            snapshot(
                appState: .background, isCharging: false,
                hasBackgroundProcessingGrant: true))
        XCTAssertEqual(decision, .blocked(reason: .chargingOnlyRequired))
    }

    func testBackgroundGrantedAndChargingProceedsWithZeroInterWindowDelay() {
        let decision = IndexPolicy.decide(
            snapshot(
                appState: .background, isCharging: true,
                hasBackgroundProcessingGrant: true))
        XCTAssertEqual(decision, .proceed(interWindowDelaySeconds: 0))
    }
}
