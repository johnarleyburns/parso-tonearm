import XCTest
@testable import TonearmWatchProtocol

/// §6.3 / C-05..C-10: the connection state machine. It is a pure value type taking `now` so the
/// two-second boundary is testable to the millisecond without waiting two seconds.
final class WatchConnectionStateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)
    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    func testActivationWithAReachablePeerOpensConnected() {
        var reducer = WatchConnectionReducer()
        let effects = reducer.apply(.activated(reachable: true), at: t0)
        XCTAssertEqual(reducer.state, .connected(lastReplyAt: t0))
        XCTAssertEqual(reducer.connectivity, .connected)
        XCTAssertTrue(effects.isEmpty, "a clean activation announces nothing")
    }

    func testActivationWithAnUnreachablePeerIsDisconnectedWithNoAlert() {
        var reducer = WatchConnectionReducer()
        let effects = reducer.apply(.activated(reachable: false), at: t0)
        XCTAssertEqual(reducer.state, .disconnected(lastConnectedAt: nil))
        // C-09 counts alerts per *outage*. Launching out of range is not an outage; there was never
        // a connection to lose, and a banner at launch would be noise.
        XCTAssertFalse(effects.contains(.announceDisconnected))
    }

    // MARK: - C-08: the sub-two-second blip

    func testABlipShorterThanTheGracePeriodNeverSwitchesTheUI() {
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)

        let dropEffects = reducer.apply(.reachabilityChanged(false), at: at(1))
        XCTAssertEqual(reducer.state, .suspectedDisconnected(since: at(1)))
        XCTAssertEqual(dropEffects, [.scheduleGraceExpiry(after: 2.0)])
        // The whole point of C-08: the *mode* does not change. `isConnectedForUI` is what gates
        // Downloads-only mode, and it stays true through the grace period. `connectivity` may show a
        // transient chip, which is the one thing a blip is allowed to move.
        XCTAssertTrue(reducer.isConnectedForUI)
        XCTAssertEqual(reducer.connectivity, .temporarilyUnavailable)

        let recoveryEffects = reducer.apply(.peerResponded, at: at(2.5))
        XCTAssertEqual(reducer.state, .connected(lastReplyAt: at(2.5)))
        XCTAssertEqual(recoveryEffects, [.cancelGraceExpiry])
        // Nothing was announced, so nothing needs un-announcing.
        XCTAssertFalse(recoveryEffects.contains(.announceReconnected))
    }

    func testAnOutageLongerThanTheGracePeriodIsConfirmedAndAnnouncedOnce() {
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)
        _ = reducer.apply(.reachabilityChanged(false), at: at(1))

        let expiry = reducer.apply(.graceElapsed, at: at(3))
        // `lastConnectedAt` is when we last *believed* we were connected — the moment suspicion
        // began, not the last reply. Between those two instants the link was still good.
        XCTAssertEqual(reducer.state, .disconnected(lastConnectedAt: at(1)))
        XCTAssertFalse(reducer.isConnectedForUI)
        XCTAssertEqual(reducer.connectivity, .unavailable)
        XCTAssertEqual(expiry, [.announceDisconnected])

        // C-09: further failures during the same outage stay silent.
        let more = reducer.apply(.immediateCommandFailed, at: at(4))
            + reducer.apply(.reachabilityChanged(false), at: at(5))
            + reducer.apply(.graceElapsed, at: at(6))
        XCTAssertFalse(more.contains(.announceDisconnected),
                       "one alert per outage, not one per failed call")
        XCTAssertEqual(reducer.state, .disconnected(lastConnectedAt: at(1)))
    }

    func testGraceExpiryArrivingAfterRecoveryIsIgnored() {
        // The real coordinator cancels its timer, but a timer that already fired can still deliver.
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)
        _ = reducer.apply(.reachabilityChanged(false), at: at(1))
        _ = reducer.apply(.peerResponded, at: at(1.5))

        let late = reducer.apply(.graceElapsed, at: at(3))
        XCTAssertEqual(reducer.state, .connected(lastReplyAt: at(1.5)))
        XCTAssertTrue(late.isEmpty)
    }

    func testReconnectAnnouncesOnceAndRearmsTheNextOutagesAlert() {
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)
        _ = reducer.apply(.reachabilityChanged(false), at: at(1))
        XCTAssertEqual(reducer.apply(.graceElapsed, at: at(3)), [.announceDisconnected])

        // C-10
        let back = reducer.apply(.peerResponded, at: at(10))
        XCTAssertEqual(reducer.state, .connected(lastReplyAt: at(10)))
        // No grace timer is pending — it already fired — so there is nothing to cancel.
        XCTAssertEqual(back, [.announceReconnected])

        // A second, separate outage gets its own single alert.
        _ = reducer.apply(.reachabilityChanged(false), at: at(11))
        XCTAssertEqual(reducer.apply(.graceElapsed, at: at(14)), [.announceDisconnected])
    }

    func testAFlappingLinkAnnouncesOncePerConfirmedOutageNotPerFlap() {
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)
        var announcements = 0
        var reconnections = 0
        var now: TimeInterval = 0

        // Ten blips, each shorter than the grace period.
        for _ in 0..<10 {
            now += 0.3
            reducer.apply(.reachabilityChanged(false), at: at(now)).forEach { if $0 == .announceDisconnected { announcements += 1 } }
            now += 0.3
            reducer.apply(.peerResponded, at: at(now)).forEach { if $0 == .announceReconnected { reconnections += 1 } }
        }
        XCTAssertEqual(announcements, 0, "no flap shorter than the grace period may alert")
        XCTAssertEqual(reconnections, 0, "and nothing was announced, so nothing reconnects")
        XCTAssertTrue(reducer.isConnectedForUI)
    }

    func testAFailedImmediateCommandStartsTheGraceRatherThanDisconnectingAtOnce() {
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)
        let effects = reducer.apply(.immediateCommandFailed, at: at(1))
        XCTAssertEqual(reducer.state, .suspectedDisconnected(since: at(1)))
        XCTAssertEqual(effects, [.scheduleGraceExpiry(after: 2.0)])
    }

    // MARK: - Terminal states

    func testProtocolIncompatibilityIsTerminalAndSurfacesUpgradeRequired() {
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)
        _ = reducer.apply(.protocolIncompatible, at: at(1))
        XCTAssertEqual(reducer.state, .incompatibleProtocol)
        XCTAssertEqual(reducer.blockingErrorCode, .protocolUpgradeRequired)
        XCTAssertEqual(reducer.connectivity, .unavailable)

        // Reachability cannot argue a build mismatch away.
        _ = reducer.apply(.reachabilityChanged(true), at: at(2))
        _ = reducer.apply(.peerResponded, at: at(3))
        XCTAssertEqual(reducer.state, .incompatibleProtocol)
    }

    func testUnpairedBlocksCommandsButRecoversWhenThePeerSpeaksAgain() {
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)
        _ = reducer.apply(.peerUnpaired, at: at(1))
        XCTAssertEqual(reducer.state, .unpaired)
        XCTAssertEqual(reducer.blockingErrorCode, .phoneUnavailable)

        // Unlike `incompatibleProtocol`, unpaired is recoverable: a message from the peer is proof
        // the pairing is back, and requiring a relaunch to notice would be a bug the user cannot fix.
        let effects = reducer.apply(.peerResponded, at: at(2))
        XCTAssertEqual(reducer.state, .connected(lastReplyAt: at(2)))
        XCTAssertFalse(effects.contains(.announceReconnected),
                       "unpairing is not an outage, so re-pairing is not a reconnect banner")
    }

    func testGracePeriodIsTwoSecondsBySpecAndConfigurableOnlyForTests() {
        XCTAssertEqual(WatchConnectionReducer.defaultGracePeriod, 2.0, accuracy: 0.0001)
        var reducer = WatchConnectionReducer(gracePeriod: 0.05)
        _ = reducer.apply(.activated(reachable: true), at: t0)
        XCTAssertEqual(reducer.apply(.reachabilityChanged(false), at: at(1)),
                       [.scheduleGraceExpiry(after: 0.05)])
    }
}
