import XCTest
import GRDB
import TonearmCore

@testable import TonearmDJ

/// Progress + governor-text mapping tests (§41.3, NFR-THERM-4). These exercise
/// the pure pieces (`AnalysisProgress.etaSeconds`, `ThermalGovernor.words`)
/// that the UI model surfaces; the view itself is covered by app-smoke.
final class AnalysisModelTests: XCTestCase {

    func testProgressFraction() {
        let p = AnalysisProgress(completed: 2, total: 10)
        XCTAssertEqual(Double(p.completed) / Double(p.total), 0.2)
    }

    func testEtaFromRate() {
        // 2 done in 10 s → 5 s/track → 40 s remaining for 8 tracks.
        let p = AnalysisProgress(completed: 2, total: 10)
        let eta = p.etaSeconds(elapsed: 10)
        XCTAssertEqual(eta ?? -1, 40, accuracy: 1e-6)
    }

    func testEtaNilWhenCompleteOrNothingDone() {
        let done = AnalysisProgress(completed: 10, total: 10)
        XCTAssertNil(done.etaSeconds(elapsed: 100))
        let none = AnalysisProgress(completed: 0, total: 5)
        XCTAssertNil(none.etaSeconds(elapsed: 100))
    }

    func testGovernorWordsSurfaceAcrossStates() {
        // The words the UI shows are derived from the pure governor function.
        let chargingFull = ThermalGovernor.words(lane: .essentials, thermalState: .nominal,
                                                 batteryLevelPercent: 90, isCharging: true,
                                                 userOverride: false, isPerforming: false)
        XCTAssertTrue(chargingFull.contains("full speed"))

        let waiting = ThermalGovernor.words(lane: .essentials, thermalState: .nominal,
                                            batteryLevelPercent: 90, isCharging: false,
                                            userOverride: false, isPerforming: false)
        XCTAssertTrue(waiting.contains("charger"))

        let warm = ThermalGovernor.words(lane: .essentials, thermalState: .serious,
                                         batteryLevelPercent: 90, isCharging: true,
                                         userOverride: false, isPerforming: false)
        XCTAssertTrue(warm.contains("warm"))
    }
}
