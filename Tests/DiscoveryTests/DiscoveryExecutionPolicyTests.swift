import Foundation
import Testing
@testable import TonearmDiscovery

@Suite struct DiscoveryExecutionPolicyTests {
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

    @Test func testPrefersGPUWhenNominalAndIdle() {
        #expect(DiscoveryExecutionPolicy.decide(snapshot()) == .gpuPreferred)
    }

    @Test func testPlaybackActiveForcesCPUEvenWhenNominal() {
        let decision = DiscoveryExecutionPolicy.decide(snapshot(isPlaybackActive: true))
        #expect(decision == .cpuOnly(reason: .playbackActive))
    }

    @Test func testPlaybackTakesPriorityOverThermalReason() {
        let decision = DiscoveryExecutionPolicy.decide(
            snapshot(thermalState: .critical, isPlaybackActive: true))
        #expect(decision == .cpuOnly(reason: .playbackActive))
    }

    @Test func testSeriousOrCriticalAlwaysForcesCPU() {
        #expect(
            DiscoveryExecutionPolicy.decide(snapshot(thermalState: .serious))
                == .cpuOnly(reason: .thermalSeriousOrCritical))
        #expect(
            DiscoveryExecutionPolicy.decide(snapshot(thermalState: .critical))
                == .cpuOnly(reason: .thermalSeriousOrCritical))
    }

    /// The core fix: a single momentary `.fair` reading must NOT immediately
    /// fall back to CPU — only a sustained one should. This is what breaks
    /// the old self-triggered debounce loop.
    @Test func testMomentaryFairDoesNotFallBackToCPU() {
        let decision = DiscoveryExecutionPolicy.decide(
            snapshot(thermalState: .fair, continuousFairOrWorseSeconds: 1))
        #expect(decision == .gpuPreferred)
    }

    @Test func testSustainedFairFallsBackToCPU() {
        let justBelow = DiscoveryExecutionPolicy.decide(snapshot(
            thermalState: .fair,
            continuousFairOrWorseSeconds: DiscoveryExecutionPolicy.fairSustainedThresholdSeconds - 1))
        #expect(justBelow == .gpuPreferred)

        let atThreshold = DiscoveryExecutionPolicy.decide(snapshot(
            thermalState: .fair,
            continuousFairOrWorseSeconds: DiscoveryExecutionPolicy.fairSustainedThresholdSeconds))
        #expect(atThreshold == .cpuOnly(reason: .thermalSustainedFair))
    }

    @Test func testRepeatedOscillationTripsCircuitBreakerEvenWhenCurrentlyNominal() {
        let decision = DiscoveryExecutionPolicy.decide(snapshot(
            thermalState: .nominal,
            recentThermalDowngradeCount: DiscoveryExecutionPolicy.oscillationLimit))
        #expect(decision == .cpuOnly(reason: .recentOscillation))
    }

    @Test func testBelowOscillationLimitStillPrefersGPU() {
        let decision = DiscoveryExecutionPolicy.decide(snapshot(
            thermalState: .nominal,
            recentThermalDowngradeCount: DiscoveryExecutionPolicy.oscillationLimit - 1))
        #expect(decision == .gpuPreferred)
    }
}
