import XCTest
@testable import TonearmDiscovery

final class DiscoveryExecutionPolicyTests: XCTestCase {
    private func snapshot(
        thermalState: DiscoveryThermalState = .nominal,
        continuousFairOrWorseSeconds: TimeInterval = 0,
        isPlaybackActive: Bool = false,
        recentThermalDowngradeCount: Int = 0
    ) -> DiscoveryExecutionPolicy.Snapshot {
        DiscoveryExecutionPolicy.Snapshot(
            thermalState: thermalState,
            continuousFairOrWorseSeconds: continuousFairOrWorseSeconds,
            isPlaybackActive: isPlaybackActive,
            recentThermalDowngradeCount: recentThermalDowngradeCount)
    }

    func testPrefersGPUWhenNominalAndIdle() {
        XCTAssertEqual(DiscoveryExecutionPolicy.decide(snapshot()), .gpuPreferred)
    }

    func testPlaybackActiveForcesCPUEvenWhenNominal() {
        let decision = DiscoveryExecutionPolicy.decide(snapshot(isPlaybackActive: true))
        XCTAssertEqual(decision, .cpuOnly(reason: .playbackActive))
    }

    func testPlaybackTakesPriorityOverThermalReason() {
        let decision = DiscoveryExecutionPolicy.decide(
            snapshot(thermalState: .critical, isPlaybackActive: true))
        XCTAssertEqual(decision, .cpuOnly(reason: .playbackActive))
    }

    func testSeriousOrCriticalAlwaysForcesCPU() {
        XCTAssertEqual(
            DiscoveryExecutionPolicy.decide(snapshot(thermalState: .serious)),
            .cpuOnly(reason: .thermalSeriousOrCritical))
        XCTAssertEqual(
            DiscoveryExecutionPolicy.decide(snapshot(thermalState: .critical)),
            .cpuOnly(reason: .thermalSeriousOrCritical))
    }

    /// The core fix: a single momentary `.fair` reading must NOT immediately
    /// fall back to CPU — only a sustained one should. This is what breaks
    /// the old self-triggered debounce loop.
    func testMomentaryFairDoesNotFallBackToCPU() {
        let decision = DiscoveryExecutionPolicy.decide(
            snapshot(thermalState: .fair, continuousFairOrWorseSeconds: 1))
        XCTAssertEqual(decision, .gpuPreferred)
    }

    func testSustainedFairFallsBackToCPU() {
        let justBelow = DiscoveryExecutionPolicy.decide(snapshot(
            thermalState: .fair,
            continuousFairOrWorseSeconds: DiscoveryExecutionPolicy.fairSustainedThresholdSeconds - 1))
        XCTAssertEqual(justBelow, .gpuPreferred)

        let atThreshold = DiscoveryExecutionPolicy.decide(snapshot(
            thermalState: .fair,
            continuousFairOrWorseSeconds: DiscoveryExecutionPolicy.fairSustainedThresholdSeconds))
        XCTAssertEqual(atThreshold, .cpuOnly(reason: .thermalSustainedFair))
    }

    func testRepeatedOscillationTripsCircuitBreakerEvenWhenCurrentlyNominal() {
        let decision = DiscoveryExecutionPolicy.decide(snapshot(
            thermalState: .nominal,
            recentThermalDowngradeCount: DiscoveryExecutionPolicy.oscillationLimit))
        XCTAssertEqual(decision, .cpuOnly(reason: .recentOscillation))
    }

    func testBelowOscillationLimitStillPrefersGPU() {
        let decision = DiscoveryExecutionPolicy.decide(snapshot(
            thermalState: .nominal,
            recentThermalDowngradeCount: DiscoveryExecutionPolicy.oscillationLimit - 1))
        XCTAssertEqual(decision, .gpuPreferred)
    }
}
