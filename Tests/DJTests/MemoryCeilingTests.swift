import XCTest
@testable import TonearmDJ

/// §43.5 / NFR-REL-4 / AT-MEM-*. The automated proxy for the user-owned
/// on-device `AT-MEM-1` (plan §2.11): the pure policy is pinned against
/// fabricated samples — ceilings per device class, the 80% shed band, the 95%
/// refuse-load band, and the §43.5 shed order — and the monitor's band
/// decisions are driven by an injected fake footprint provider.
@MainActor
final class MemoryCeilingTests: XCTestCase {

    // MARK: - Ceiling per device class

    func testDeviceClassMapsTotalRAMToTheSpecClasses() {
        XCTAssertEqual(MemoryCeiling.deviceClass(totalRAMBytes: 6_000_000_000), .iphone6GB)
        XCTAssertEqual(MemoryCeiling.deviceClass(totalRAMBytes: 8_000_000_000), .iphone8GB)
        XCTAssertEqual(MemoryCeiling.deviceClass(totalRAMBytes: 12_000_000_000), .ipad)
    }

    func testCeilingBytesPerDeviceClass() {
        XCTAssertEqual(MemoryCeiling.ceilingBytes(for: .iphone6GB), 1_000_000_000, "1.0 GB")
        XCTAssertEqual(MemoryCeiling.ceilingBytes(for: .iphone8GB), 1_400_000_000, "1.4 GB")
        XCTAssertEqual(MemoryCeiling.ceilingBytes(for: .ipad), 2_000_000_000, "2.0 GB")
        XCTAssertEqual(MemoryCeiling.ceilingBytes(for: .other), .max, "no hard ceiling off a device")
    }

    // MARK: - Pressure bands (80% shed / 95% refuse)

    func testUnderBudgetBelow80Percent() {
        let ceiling = MemoryCeiling.ceilingBytes(for: .iphone8GB)
        let footprint = (ceiling * 79) / 100
        XCTAssertEqual(MemoryCeiling.pressure(footprintBytes: footprint, ceilingBytes: ceiling), .underBudget)
    }

    func testSheddingAt80Percent() {
        let ceiling = MemoryCeiling.ceilingBytes(for: .iphone8GB)
        let footprint = (ceiling * 80) / 100
        XCTAssertEqual(MemoryCeiling.pressure(footprintBytes: footprint, ceilingBytes: ceiling), .shedding)
    }

    func testStillSheddingJustBelow95Percent() {
        let ceiling = MemoryCeiling.ceilingBytes(for: .iphone8GB)
        let footprint = (ceiling * 94) / 100
        XCTAssertEqual(MemoryCeiling.pressure(footprintBytes: footprint, ceilingBytes: ceiling), .shedding)
    }

    func testRefusesLoadAt95Percent() {
        let ceiling = MemoryCeiling.ceilingBytes(for: .iphone8GB)
        let footprint = (ceiling * 95) / 100
        XCTAssertEqual(MemoryCeiling.pressure(footprintBytes: footprint, ceilingBytes: ceiling), .refuseLoad)
    }

    func testRefusesLoadAtTheCeiling() {
        let ceiling = MemoryCeiling.ceilingBytes(for: .iphone6GB)
        XCTAssertEqual(MemoryCeiling.pressure(footprintBytes: ceiling, ceilingBytes: ceiling), .refuseLoad)
    }

    func testNoCeilingClassNeverRefuses() {
        XCTAssertEqual(MemoryCeiling.pressure(footprintBytes: .max, ceilingBytes: .max), .underBudget)
    }

    // MARK: - Shed order

    func testShedOrderIsTheSpecOrder() {
        XCTAssertEqual(MemoryCeiling.ShedOrder.normativeOrder,
                       [.waveformLODs, .nonFocusedDeckStemTails, .onDemandSeparation, .analysis],
                       "§43.5's shed order: waveform LODs → non-focused deck's stem tails → on-demand separation → analysis")
    }

    // MARK: - Monitor decisions against fabricated samples

    func testMonitorRefusesDeckLoadAt95PercentWithAnHonestMessage() {
        let ceiling = MemoryCeiling.ceilingBytes(for: .iphone8GB)
        let monitor = MemoryCeilingMonitor(provider: StaticFootprintProvider(bytes: (ceiling * 95) / 100),
                                           totalRAMBytes: 8_000_000_000)
        monitor.sampleNow()
        XCTAssertEqual(monitor.pressure, .refuseLoad)
        XCTAssertFalse(monitor.shouldAllowDeckLoad(), "crossing 95% refuses the next deck load (§43.5)")
        let message = monitor.refusalMessage()
        XCTAssertFalse(message.isEmpty, "the refusal is an honest message, not a silent failure")
        XCTAssertTrue(message.contains("95"), "the message states the measured pressure: \(message)")
    }

    func testMonitorAllowsDeckLoadUnderBudget() {
        let ceiling = MemoryCeiling.ceilingBytes(for: .iphone6GB)
        let monitor = MemoryCeilingMonitor(provider: StaticFootprintProvider(bytes: ceiling / 2),
                                           totalRAMBytes: 6_000_000_000)
        XCTAssertTrue(monitor.shouldAllowDeckLoad())
        XCTAssertEqual(monitor.pressure, .underBudget)
    }

    func testMonitorShedsAt80PercentButStillLoads() {
        let ceiling = MemoryCeiling.ceilingBytes(for: .ipad)
        let monitor = MemoryCeilingMonitor(provider: StaticFootprintProvider(bytes: (ceiling * 80) / 100),
                                           totalRAMBytes: 12_000_000_000)
        monitor.sampleNow()
        XCTAssertEqual(monitor.pressure, .shedding)
        XCTAssertTrue(monitor.shouldAllowDeckLoad(), "shedding is not refusal — only 95% refuses")
    }

    func testMonitorReflectsTheDeviceClassCeiling() {
        let iphone = MemoryCeilingMonitor(provider: StaticFootprintProvider(bytes: 1_100_000_000),
                                          totalRAMBytes: 8_000_000_000)
        iphone.sampleNow()
        XCTAssertEqual(iphone.deviceClass, .iphone8GB)
        XCTAssertEqual(iphone.ceilingBytes, 1_400_000_000)
        // 1.1 GB is under the 1.4 GB iPhone ceiling…
        XCTAssertEqual(iphone.pressure, .underBudget)

        let ipad = MemoryCeilingMonitor(provider: StaticFootprintProvider(bytes: 1_100_000_000),
                                        totalRAMBytes: 12_000_000_000)
        ipad.sampleNow()
        XCTAssertEqual(ipad.deviceClass, .ipad)
        XCTAssertEqual(ipad.ceilingBytes, 2_000_000_000)
        XCTAssertEqual(ipad.pressure, .underBudget)
    }

    func testProbeFailureLeavesTheBaseline() {
        let monitor = MemoryCeilingMonitor(provider: StaticFootprintProvider(bytes: nil),
                                           totalRAMBytes: 8_000_000_000)
        monitor.sampleNow()
        XCTAssertEqual(monitor.footprintBytes, 0)
        XCTAssertEqual(monitor.pressure, .underBudget, "a failed probe never looks like a drop in pressure")
    }

    func testMonitorPublishesTheSpecShedOrder() {
        let monitor = MemoryCeilingMonitor(provider: StaticFootprintProvider(bytes: 0),
                                           totalRAMBytes: 8_000_000_000)
        XCTAssertEqual(monitor.shedOrder,
                       [.waveformLODs, .nonFocusedDeckStemTails, .onDemandSeparation, .analysis])
    }
}

/// A deterministic `task_vm_info` stand-in: returns a canned footprint (or
/// `nil` to simulate a failed kernel probe).
private struct StaticFootprintProvider: FootprintProviding {
    let bytes: UInt64?
    func physicalFootprintBytes() -> UInt64? { bytes }
}
