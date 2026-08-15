import XCTest
@testable import TonearmDJ

/// NFR-REL-2 / §34A.5 — the graph's liveness, and the state the app is allowed
/// to display about it.
///
/// The incident these are written against: the render callback stopped being
/// pulled, `isRunning` went on answering `true`, no notification arrived, and
/// the app displayed a running recording timer over a dead engine for fourteen
/// minutes. Every case below is a piece of that story.
final class EngineLivenessTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_000)

    // MARK: - The stall detector (the signal that actually caught it)

    func testFrozenClockWhileADeckPlaysIsAStall() {
        var monitor = EngineLivenessMonitor(stallSeconds: 2.0)

        XCTAssertEqual(monitor.observe(masterSample: 1_000, anyDeckPlaying: true,
                                       isRunning: true, now: start), .live)
        // The clock stops. `isRunning` keeps lying, exactly as it did.
        XCTAssertEqual(monitor.observe(masterSample: 1_000, anyDeckPlaying: true,
                                       isRunning: true, now: start.addingTimeInterval(1.0)),
                       .live, "one second of no advance is a hiccup, not a failure")
        XCTAssertEqual(monitor.observe(masterSample: 1_000, anyDeckPlaying: true,
                                       isRunning: true, now: start.addingTimeInterval(2.0)),
                       .stopped(reason: .renderStalled),
                       "a clock frozen for the stall window is a graph that is not being rendered")
    }

    func testAFrozenClockWithNothingPlayingIsNotAStall() {
        var monitor = EngineLivenessMonitor(stallSeconds: 2.0)
        // Browsing for the next track: the clock is still because nothing is
        // playing. Calling this a failure would put a banner over the app
        // precisely when the user is doing something ordinary.
        for second in 0...10 {
            XCTAssertEqual(monitor.observe(masterSample: 500, anyDeckPlaying: false,
                                           isRunning: true,
                                           now: start.addingTimeInterval(Double(second))),
                           .live)
        }
    }

    func testIdleTimeDoesNotCountTowardTheNextStall() {
        var monitor = EngineLivenessMonitor(stallSeconds: 2.0)
        // Sixty seconds paused…
        _ = monitor.observe(masterSample: 500, anyDeckPlaying: false, isRunning: true, now: start)
        _ = monitor.observe(masterSample: 500, anyDeckPlaying: false, isRunning: true,
                            now: start.addingTimeInterval(60))
        // …then play. The first sample after the deck starts must not be judged
        // against a clock that has been still for a minute.
        XCTAssertEqual(monitor.observe(masterSample: 500, anyDeckPlaying: true, isRunning: true,
                                       now: start.addingTimeInterval(60.1)),
                       .live)
    }

    func testAnAdvancingClockStaysLive() {
        var monitor = EngineLivenessMonitor(stallSeconds: 2.0)
        for tick in 0..<100 {
            let state = monitor.observe(masterSample: Int64(tick) * 512,
                                        anyDeckPlaying: true, isRunning: true,
                                        now: start.addingTimeInterval(Double(tick) * 0.1))
            XCTAssertEqual(state, .live)
        }
    }

    // MARK: - The signals that arrive with a reason

    func testNotRunningIsStoppedImmediately() {
        var monitor = EngineLivenessMonitor(stallSeconds: 2.0)
        XCTAssertEqual(monitor.observe(masterSample: 0, anyDeckPlaying: true,
                                       isRunning: false, now: start),
                       .stopped(reason: .notRunning),
                       "no stall window: the engine has said it is not running")
    }

    func testAReportedReasonWinsAndPersists() {
        var monitor = EngineLivenessMonitor(stallSeconds: 2.0)
        monitor.report(.configurationChange)
        // Even with a healthy-looking sample, the reported reason stands — it
        // is better information than the inference.
        XCTAssertEqual(monitor.observe(masterSample: 4_096, anyDeckPlaying: true,
                                       isRunning: true, now: start),
                       .stopped(reason: .configurationChange))
        XCTAssertEqual(monitor.observe(masterSample: 8_192, anyDeckPlaying: true,
                                       isRunning: true, now: start.addingTimeInterval(1)),
                       .stopped(reason: .configurationChange),
                       "a stopped graph does not un-stop itself because a sample looked fine")
    }

    func testRecoveryClearsAndReArms() {
        var monitor = EngineLivenessMonitor(stallSeconds: 2.0)
        _ = monitor.observe(masterSample: 100, anyDeckPlaying: true, isRunning: true, now: start)
        XCTAssertEqual(monitor.observe(masterSample: 100, anyDeckPlaying: true, isRunning: true,
                                       now: start.addingTimeInterval(3)),
                       .stopped(reason: .renderStalled))

        monitor.recovered(now: start.addingTimeInterval(3))
        // The recovered graph gets a fresh window. Its clock may legitimately
        // resume at the sample it froze at, and re-stalling instantly would
        // make recovery look impossible.
        XCTAssertEqual(monitor.observe(masterSample: 100, anyDeckPlaying: true, isRunning: true,
                                       now: start.addingTimeInterval(3.1)),
                       .live)
        XCTAssertEqual(monitor.observe(masterSample: 612, anyDeckPlaying: true, isRunning: true,
                                       now: start.addingTimeInterval(3.2)),
                       .live)
    }

    // MARK: - What the user is told

    func testEveryReasonNamesTheConsequence() {
        // The message exists to replace a lie, so it has to say something. A
        // reason that renders as an empty banner is worse than no banner.
        for reason: EngineLiveness.StopReason in [.configurationChange, .mediaServicesReset,
                                                  .notRunning, .renderStalled] {
            XCTAssertFalse(reason.message.isEmpty)
            XCTAssertTrue(reason.message.lowercased().contains("stop"),
                          "\(reason) should say the engine stopped: '\(reason.message)'")
        }
    }
}
