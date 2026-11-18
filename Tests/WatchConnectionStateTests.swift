import Testing
@testable import TonearmWatchProtocol

/// §6.3 / C-05..C-10: the connection state machine. It is a pure value type taking `now` so the
/// two-second boundary is testable to the millisecond without waiting two seconds.
@Suite struct WatchConnectionStateTests {
    private let t0 = Date(timeIntervalSince1970: 10_000)
    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    @Test func testActivationWithAReachablePeerOpensConnected() {
        var reducer = WatchConnectionReducer()
        let effects = reducer.apply(.activated(reachable: true), at: t0)
        #expect(reducer.state == .connected(lastReplyAt: t0))
        #expect(reducer.connectivity == .connected)
        #expect(effects.isEmpty, "a clean activation announces nothing")
    }

    @Test func testActivationWithAnUnreachablePeerIsDisconnectedWithNoAlert() {
        var reducer = WatchConnectionReducer()
        let effects = reducer.apply(.activated(reachable: false), at: t0)
        #expect(reducer.state == .disconnected(lastConnectedAt: nil))
        // C-09 counts alerts per *outage*. Launching out of range is not an outage; there was never
        // a connection to lose, and a banner at launch would be noise.
        #expect(!effects.contains(.announceDisconnected))
    }

    // MARK: - C-08: the sub-two-second blip

    @Test func testABlipShorterThanTheGracePeriodNeverSwitchesTheUI() {
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)

        let dropEffects = reducer.apply(.reachabilityChanged(false), at: at(1))
        #expect(reducer.state == .suspectedDisconnected(since: at(1)))
        #expect(dropEffects == [.scheduleGraceExpiry(after: 2.0)])
        // The whole point of C-08: the *mode* does not change. `isConnectedForUI` is what gates
        // Downloads-only mode, and it stays true through the grace period. `connectivity` may show a
        // transient chip, which is the one thing a blip is allowed to move.
        #expect(reducer.isConnectedForUI)
        #expect(reducer.connectivity == .temporarilyUnavailable)

        let recoveryEffects = reducer.apply(.peerResponded, at: at(2.5))
        #expect(reducer.state == .connected(lastReplyAt: at(2.5)))
        #expect(recoveryEffects == [.cancelGraceExpiry])
        // Nothing was announced, so nothing needs un-announcing.
        #expect(!recoveryEffects.contains(.announceReconnected))
    }

    @Test func testAnOutageLongerThanTheGracePeriodIsConfirmedAndAnnouncedOnce() {
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)
        _ = reducer.apply(.reachabilityChanged(false), at: at(1))

        let expiry = reducer.apply(.graceElapsed, at: at(3))
        // `lastConnectedAt` is when we last *believed* we were connected — the moment suspicion
        // began, not the last reply. Between those two instants the link was still good.
        #expect(reducer.state == .disconnected(lastConnectedAt: at(1)))
        #expect(!reducer.isConnectedForUI)
        #expect(reducer.connectivity == .unavailable)
        #expect(expiry == [.announceDisconnected])

        // C-09: further failures during the same outage stay silent.
        let more = reducer.apply(.immediateCommandFailed, at: at(4))
            + reducer.apply(.reachabilityChanged(false), at: at(5))
            + reducer.apply(.graceElapsed, at: at(6))
        #expect(!more.contains(.announceDisconnected),
                       "one alert per outage, not one per failed call")
        #expect(reducer.state == .disconnected(lastConnectedAt: at(1)))
    }

    @Test func testGraceExpiryArrivingAfterRecoveryIsIgnored() {
        // The real coordinator cancels its timer, but a timer that already fired can still deliver.
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)
        _ = reducer.apply(.reachabilityChanged(false), at: at(1))
        _ = reducer.apply(.peerResponded, at: at(1.5))

        let late = reducer.apply(.graceElapsed, at: at(3))
        #expect(reducer.state == .connected(lastReplyAt: at(1.5)))
        #expect(late.isEmpty)
    }

    @Test func testReconnectAnnouncesOnceAndRearmsTheNextOutagesAlert() {
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)
        _ = reducer.apply(.reachabilityChanged(false), at: at(1))
        #expect(reducer.apply(.graceElapsed, at: at(3)) == [.announceDisconnected])

        // C-10
        let back = reducer.apply(.peerResponded, at: at(10))
        #expect(reducer.state == .connected(lastReplyAt: at(10)))
        // No grace timer is pending — it already fired — so there is nothing to cancel.
        #expect(back == [.announceReconnected])

        // A second, separate outage gets its own single alert.
        _ = reducer.apply(.reachabilityChanged(false), at: at(11))
        #expect(reducer.apply(.graceElapsed, at: at(14)) == [.announceDisconnected])
    }

    @Test func testAFlappingLinkAnnouncesOncePerConfirmedOutageNotPerFlap() {
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
        #expect(announcements == 0, "no flap shorter than the grace period may alert")
        #expect(reconnections == 0, "and nothing was announced, so nothing reconnects")
        #expect(reducer.isConnectedForUI)
    }

    @Test func testAFailedImmediateCommandStartsTheGraceRatherThanDisconnectingAtOnce() {
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)
        let effects = reducer.apply(.immediateCommandFailed, at: at(1))
        #expect(reducer.state == .suspectedDisconnected(since: at(1)))
        #expect(effects == [.scheduleGraceExpiry(after: 2.0)])
    }

    // MARK: - Terminal states

    @Test func testProtocolIncompatibilityIsTerminalAndSurfacesUpgradeRequired() {
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)
        _ = reducer.apply(.protocolIncompatible, at: at(1))
        #expect(reducer.state == .incompatibleProtocol)
        #expect(reducer.blockingErrorCode == .protocolUpgradeRequired)
        #expect(reducer.connectivity == .unavailable)

        // Reachability cannot argue a build mismatch away.
        _ = reducer.apply(.reachabilityChanged(true), at: at(2))
        _ = reducer.apply(.peerResponded, at: at(3))
        #expect(reducer.state == .incompatibleProtocol)
    }

    @Test func testUnpairedBlocksCommandsButRecoversWhenThePeerSpeaksAgain() {
        var reducer = WatchConnectionReducer()
        _ = reducer.apply(.activated(reachable: true), at: t0)
        _ = reducer.apply(.peerUnpaired, at: at(1))
        #expect(reducer.state == .unpaired)
        #expect(reducer.blockingErrorCode == .phoneUnavailable)

        // Unlike `incompatibleProtocol`, unpaired is recoverable: a message from the peer is proof
        // the pairing is back, and requiring a relaunch to notice would be a bug the user cannot fix.
        let effects = reducer.apply(.peerResponded, at: at(2))
        #expect(reducer.state == .connected(lastReplyAt: at(2)))
        #expect(!effects.contains(.announceReconnected),
                       "unpairing is not an outage, so re-pairing is not a reconnect banner")
    }

    @Test func testGracePeriodIsTwoSecondsBySpecAndConfigurableOnlyForTests() {
        #expect(abs(WatchConnectionReducer.defaultGracePeriod - 2.0) <= 0.0001)
        var reducer = WatchConnectionReducer(gracePeriod: 0.05)
        _ = reducer.apply(.activated(reachable: true), at: t0)
        #expect(reducer.apply(.reachabilityChanged(false), at: at(1)) ==
                       [.scheduleGraceExpiry(after: 0.05)])
    }
}
