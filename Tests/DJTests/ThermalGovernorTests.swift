import XCTest

@testable import TonearmDJ

/// Decision-table tests for the thermal governor (§43.7 — one test per row,
/// NFR-THERM-2/4, FR-ANL-7/8). The table is normative; these tests pin it.
final class ThermalGovernorTests: XCTestCase {

    // MARK: - The §43.7 table, analysis lanes

    func testStage1EssentialsFullAtNominalAndFair() {
        XCTAssertEqual(ThermalGovernor.decision(for: .essentials, thermalState: .nominal), .full)
        XCTAssertEqual(ThermalGovernor.decision(for: .essentials, thermalState: .fair), .full)
    }

    func testStage1EssentialsHalfConcurrencyAtSerious() {
        XCTAssertEqual(ThermalGovernor.decision(for: .essentials, thermalState: .serious), .halfConcurrency)
    }

    func testStage1EssentialsPausedAtCritical() {
        XCTAssertEqual(ThermalGovernor.decision(for: .essentials, thermalState: .critical), .paused)
    }

    func testStage2Embeddings() {
        XCTAssertEqual(ThermalGovernor.decision(for: .embeddings, thermalState: .nominal), .full)
        XCTAssertEqual(ThermalGovernor.decision(for: .embeddings, thermalState: .fair), .halfConcurrency)
        XCTAssertEqual(ThermalGovernor.decision(for: .embeddings, thermalState: .serious), .paused)
        XCTAssertEqual(ThermalGovernor.decision(for: .embeddings, thermalState: .critical), .paused)
    }

    func testStage3Stems() {
        XCTAssertEqual(ThermalGovernor.decision(for: .stems, thermalState: .nominal), .full)
        XCTAssertEqual(ThermalGovernor.decision(for: .stems, thermalState: .fair), .halfConcurrency)
        XCTAssertEqual(ThermalGovernor.decision(for: .stems, thermalState: .serious), .paused)
        XCTAssertEqual(ThermalGovernor.decision(for: .stems, thermalState: .critical), .paused)
    }

    // MARK: - Power/battery gates (independent of thermal state)

    func testBulkRequiresPowerOrOverride() {
        XCTAssertTrue(ThermalGovernor.powerAllowsBulk(batteryLevelPercent: 80, isCharging: true, userOverride: false))
        XCTAssertTrue(ThermalGovernor.powerAllowsBulk(batteryLevelPercent: 80, isCharging: false, userOverride: true))
        XCTAssertFalse(ThermalGovernor.powerAllowsBulk(batteryLevelPercent: 80, isCharging: false, userOverride: false))
        XCTAssertFalse(ThermalGovernor.powerAllowsBulk(batteryLevelPercent: 15, isCharging: true, userOverride: true))
        XCTAssertFalse(ThermalGovernor.powerAllowsBulk(batteryLevelPercent: 15, isCharging: false, userOverride: false))
    }

    func testPerformancePinsLanesPaused() {
        XCTAssertTrue(ThermalGovernor.performancePinsLanesPaused(true))
        XCTAssertFalse(ThermalGovernor.performancePinsLanesPaused(false))
    }

    // MARK: - Hysteresis (§43.7 "resume one state below where shed")

    func testHysteresisShedAtSeriousResumesAtNominal() {
        // A lane paused at .serious resumes at .nominal, not at .fair.
        let threshold = ThermalGovernor.resumeThreshold(for: .essentials, shedAt: .serious)
        XCTAssertEqual(threshold, .nominal)

        XCTAssertFalse(ThermalGovernor.canRun(lane: .essentials, currentThermalState: .fair,
                                              shedAtThermalState: .serious))
        XCTAssertFalse(ThermalGovernor.canRun(lane: .essentials, currentThermalState: .serious,
                                              shedAtThermalState: .serious))
        XCTAssertTrue(ThermalGovernor.canRun(lane: .essentials, currentThermalState: .nominal,
                                             shedAtThermalState: .serious))
    }

    func testHysteresisShedAtCriticalResumesAtNominal() {
        let threshold = ThermalGovernor.resumeThreshold(for: .essentials, shedAt: .critical)
        XCTAssertEqual(threshold, .nominal)
        XCTAssertFalse(ThermalGovernor.canRun(lane: .essentials, currentThermalState: .serious,
                                              shedAtThermalState: .critical))
        XCTAssertTrue(ThermalGovernor.canRun(lane: .essentials, currentThermalState: .nominal,
                                             shedAtThermalState: .critical))
    }

    func testNeverShedRunsAlways() {
        XCTAssertTrue(ThermalGovernor.canRun(lane: .essentials, currentThermalState: .critical,
                                             shedAtThermalState: nil))
    }

    // MARK: - Human words (NFR-THERM-4)

    func testWordsReflectState() {
        XCTAssertTrue(ThermalGovernor.words(lane: .essentials, thermalState: .nominal,
                                            batteryLevelPercent: 80, isCharging: true,
                                            userOverride: false, isPerforming: false)
                          .hasPrefix("running"))
        XCTAssertTrue(ThermalGovernor.words(lane: .essentials, thermalState: .serious,
                                            batteryLevelPercent: 80, isCharging: true,
                                            userOverride: false, isPerforming: false)
                          .contains("warm"))
        XCTAssertTrue(ThermalGovernor.words(lane: .essentials, thermalState: .nominal,
                                            batteryLevelPercent: 80, isCharging: false,
                                            userOverride: false, isPerforming: false)
                          .contains("charger"))
        XCTAssertTrue(ThermalGovernor.words(lane: .essentials, thermalState: .nominal,
                                            batteryLevelPercent: 15, isCharging: true,
                                            userOverride: false, isPerforming: false)
                          .contains("20%"))
        XCTAssertTrue(ThermalGovernor.words(lane: .essentials, thermalState: .nominal,
                                            batteryLevelPercent: 80, isCharging: true,
                                            userOverride: false, isPerforming: true)
                          .contains("performance"))
    }
}
