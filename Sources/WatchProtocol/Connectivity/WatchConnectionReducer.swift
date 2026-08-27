import Foundation

/// §6.3 — connection state, as a pure state machine.
///
/// The reason this is a value type with an explicit `now` parameter rather than an actor holding a
/// `Timer` is C-08: "a raw reachability blip shorter than two seconds does not switch the whole
/// UI". A timer-driven implementation can only be tested by waiting two real seconds; a reducer
/// that is handed its own clock can be tested at 1.9 s and 2.1 s in microseconds, and the driver
/// that owns the real timer stays small enough to read.
///
/// The reducer never performs an effect. It returns them, and `WatchConnectionMonitor` runs them.
public struct WatchConnectionReducer: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case activating
        case connected(lastReplyAt: Date)
        case suspectedDisconnected(since: Date)
        case disconnected(lastConnectedAt: Date?)
        case incompatibleProtocol
        case unpaired
    }

    public enum Event: Equatable, Sendable {
        /// Session activation finished. `reachable` is the reachability the session reports.
        case activated(reachable: Bool)
        case reachabilityChanged(Bool)
        /// Any successful reply, application context, or user-info delivery from the peer.
        case peerResponded
        /// An immediate command failed for a transport reason (not a domain error).
        case immediateCommandFailed
        /// The grace period scheduled by `scheduleGraceExpiry` elapsed without a recovery.
        case graceElapsed
        case protocolIncompatible
        case peerUnpaired
    }

    public enum Effect: Equatable, Sendable {
        case scheduleGraceExpiry(after: TimeInterval)
        case cancelGraceExpiry
        /// C-09: exactly one haptic/banner per outage, on the confirmed connected → disconnected
        /// edge only.
        case announceDisconnected
        /// C-10: restore connected features. Never replaces the local queue or navigation.
        case announceReconnected
    }

    /// §6.3's two seconds. Configurable only so tests can be explicit about the boundary.
    public static let defaultGracePeriod: TimeInterval = 2.0

    public private(set) var state: State
    public let gracePeriod: TimeInterval

    /// Whether the *confirmed* outage has already been announced. Reset on reconnect, which is what
    /// makes "one alert per outage" true across a flapping link rather than one alert per callback.
    private var hasAnnouncedOutage = false

    public init(state: State = .activating, gracePeriod: TimeInterval = WatchConnectionReducer.defaultGracePeriod) {
        self.state = state
        self.gracePeriod = gracePeriod
    }

    public mutating func apply(_ event: Event, at now: Date) -> [Effect] {
        switch event {
        case .protocolIncompatible:
            // A-07: an incompatible peer is a terminal display state. Local downloads are untouched;
            // nothing here deletes or hides them.
            guard state != .incompatibleProtocol else { return [] }
            let wasConnected = isConnectedForUI
            state = .incompatibleProtocol
            return wasConnected ? [.cancelGraceExpiry] : []

        case .peerUnpaired:
            guard state != .unpaired else { return [] }
            state = .unpaired
            hasAnnouncedOutage = false
            return [.cancelGraceExpiry]

        case .activated(let reachable):
            if reachable { return connect(at: now) }
            // Activation that reports an unreachable peer is not an outage — there was never a
            // connection to lose, so it must not fire the disconnect haptic.
            state = .disconnected(lastConnectedAt: nil)
            return []

        case .reachabilityChanged(true), .peerResponded:
            return connect(at: now)

        case .reachabilityChanged(false), .immediateCommandFailed:
            return suspect(at: now)

        case .graceElapsed:
            guard case .suspectedDisconnected(let since) = state else { return [] }
            state = .disconnected(lastConnectedAt: since)
            guard !hasAnnouncedOutage else { return [] }
            hasAnnouncedOutage = true
            return [.announceDisconnected]
        }
    }

    private mutating func connect(at now: Date) -> [Effect] {
        switch state {
        case .incompatibleProtocol:
            // Only a fresh negotiation clears this, not a reachability callback.
            return []
        case .connected:
            state = .connected(lastReplyAt: now)
            return []
        case .suspectedDisconnected:
            // The blip resolved inside the grace period: cancel, and stay silent. The UI never
            // moved, so there is nothing to announce.
            state = .connected(lastReplyAt: now)
            return [.cancelGraceExpiry]
        case .activating, .unpaired:
            state = .connected(lastReplyAt: now)
            hasAnnouncedOutage = false
            return []
        case .disconnected:
            state = .connected(lastReplyAt: now)
            let announce = hasAnnouncedOutage
            hasAnnouncedOutage = false
            return announce ? [.announceReconnected] : []
        }
    }

    private mutating func suspect(at now: Date) -> [Effect] {
        switch state {
        case .connected:
            state = .suspectedDisconnected(since: now)
            return [.scheduleGraceExpiry(after: gracePeriod)]
        case .activating:
            // Never confirmed connected, so there is no outage edge to announce; go straight to the
            // honest state without a grace period nobody is waiting on.
            state = .disconnected(lastConnectedAt: nil)
            return []
        case .suspectedDisconnected, .disconnected, .incompatibleProtocol, .unpaired:
            return []
        }
    }

    // MARK: - Presentation

    /// §6.3: "Active command failures may surface immediately on the command while the global mode
    /// waits for the grace period." `suspectedDisconnected` therefore still reads as connected here.
    public var isConnectedForUI: Bool {
        switch state {
        case .connected, .suspectedDisconnected: true
        case .activating, .disconnected, .incompatibleProtocol, .unpaired: false
        }
    }

    public var connectivity: WatchConnectivityState {
        switch state {
        case .activating: .opening
        case .connected: .connected
        case .suspectedDisconnected: .temporarilyUnavailable
        case .disconnected, .incompatibleProtocol, .unpaired: .unavailable
        }
    }

    /// The code an immediate command should fail with right now, or `nil` when commands may run.
    public var blockingErrorCode: WatchProtocolErrorCode? {
        switch state {
        case .connected, .suspectedDisconnected: nil
        case .incompatibleProtocol: .protocolUpgradeRequired
        case .activating, .disconnected, .unpaired: .phoneUnavailable
        }
    }
}

extension WatchConnectionReducer.State {
    /// A confirmed outage, as opposed to the suspicion the grace period is still resolving. The
    /// distinction is what lets a caller renegotiate after a real absence without doing it per blip.
    public var isConfirmedDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }
}
