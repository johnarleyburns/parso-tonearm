import Foundation

/// A deterministic, in-process stand-in for a paired WCSession, used by every Phase 3 integration
/// test and by the injected-transport simulator harness (§11.3).
///
/// It ships in the product rather than in a test target on purpose: the same link has to be
/// injectable into the real app for the deterministic UI harness, and a copy of it living only in
/// `Tests/` would drift from the one the harness uses.
///
/// Everything it can do wrong, it does on request and never by accident — no timers, no random
/// latency, no background queues. Faults are *held* deliveries the test releases in the order it
/// chooses, which is how "out-of-order" and "late reply" become assertions instead of races.
public actor WatchFakeDuplexLink {
    public enum Side: String, Sendable, CaseIterable {
        case phone, watch
        public var peer: Side { self == .phone ? .watch : .phone }
    }

    /// One recorded delivery, for assertions about what actually crossed the link.
    public struct Delivery: Equatable, Sendable {
        public var from: Side
        public var channel: WatchTransportChannel
        public var kind: WatchMessageKind?
        public var messageID: UUID?
    }

    private var inbound: [Side: any WatchProtocolInbound] = [:]
    private var reachable = true
    private var duplicateDeliveries = false
    private var swallowImmediateReplies = false
    private var heldUserInfo: [(Side, Data)] = []
    private var holdingUserInfo = false
    private var contexts: [Side: Data] = [:]

    public private(set) var deliveries: [Delivery] = []

    public init() {}

    // MARK: - Wiring

    public func attach(_ endpoint: any WatchProtocolInbound, as side: Side) {
        inbound[side] = endpoint
    }

    public nonisolated func transport(for side: Side) -> any WatchProtocolTransport {
        WatchFakeTransport(link: self, side: side)
    }

    // MARK: - Fault injection

    public func setReachable(_ value: Bool) { reachable = value }
    /// C-05: every user-info delivery is made twice, so idempotency is exercised on every message
    /// rather than on a hand-picked one.
    public func setDuplicateDeliveries(_ value: Bool) { duplicateDeliveries = value }
    /// Makes `sendImmediate` never produce a reply, so the caller's deadline is what ends the wait.
    public func setSwallowImmediateReplies(_ value: Bool) { swallowImmediateReplies = value }

    /// Parks durable deliveries instead of handing them over. `flushHeldUserInfo(reversed:)` then
    /// releases them in the order the test wants — C-06's out-of-order convergence.
    public func setHoldingUserInfo(_ value: Bool) { holdingUserInfo = value }

    public func flushHeldUserInfo(reversed: Bool = false) async {
        let pending = reversed ? Array(heldUserInfo.reversed()) : heldUserInfo
        heldUserInfo.removeAll()
        holdingUserInfo = false
        for (from, data) in pending { await deliverUserInfo(from: from, data: data) }
    }

    public func heldUserInfoCount() -> Int { heldUserInfo.count }

    /// C-01: the context a session already holds at activation time.
    public func latestApplicationContext(from side: Side) -> Data? { contexts[side] }

    public func resetDeliveries() { deliveries.removeAll() }

    public func deliveredKinds(from side: Side? = nil) -> [WatchMessageKind] {
        deliveries.filter { side == nil || $0.from == side }.compactMap(\.kind)
    }

    // MARK: - Channels

    fileprivate func currentlyReachable() -> Bool { reachable }
    fileprivate func swallowsImmediateReplies() -> Bool { swallowImmediateReplies }

    /// Records a request that will never be answered. Kept separate from `sendImmediate` so the
    /// endpoint can do its waiting *outside* the link's isolation — an hour-long sleep inside the
    /// actor would wedge every other channel too, which is a fault the real link does not have.
    fileprivate func recordUnanswered(from side: Side, data: Data) {
        record(from: side, channel: .immediate, data: data)
    }

    fileprivate func sendImmediate(from side: Side, data: Data) async throws -> Data {
        record(from: side, channel: .immediate, data: data)
        guard reachable else { throw WatchProtocolFault(code: .phoneUnavailable) }
        guard let peer = inbound[side.peer] else { throw WatchProtocolFault(code: .phoneUnavailable) }
        guard let reply = await peer.receiveImmediate(data) else {
            throw WatchProtocolFault(code: .contentNotFound)
        }
        return reply
    }

    fileprivate func updateApplicationContext(from side: Side, data: Data) async {
        // §5.2: coalesced, newest only. Overwriting here is the behavior, not a shortcut.
        contexts[side] = data
        record(from: side, channel: .applicationContext, data: data)
        guard reachable, let peer = inbound[side.peer] else { return }
        await peer.receiveApplicationContext(data)
    }

    /// Replays the stored context into the peer, the way a session hands over
    /// `receivedApplicationContext` at activation.
    public func replayApplicationContext(from side: Side) async {
        guard let data = contexts[side], let peer = inbound[side.peer] else { return }
        await peer.receiveApplicationContext(data)
    }

    fileprivate func transferUserInfo(from side: Side, data: Data) async {
        record(from: side, channel: .userInfo, data: data)
        guard holdingUserInfo == false else {
            heldUserInfo.append((side, data))
            if duplicateDeliveries { heldUserInfo.append((side, data)) }
            return
        }
        await deliverUserInfo(from: side, data: data)
    }

    private func deliverUserInfo(from side: Side, data: Data) async {
        guard let peer = inbound[side.peer] else { return }
        await peer.receiveUserInfo(data)
        if duplicateDeliveries { await peer.receiveUserInfo(data) }
    }

    fileprivate func transferFile(from side: Side, url: URL, metadata: [String: String]) async {
        deliveries.append(Delivery(from: side, channel: .file, kind: nil, messageID: nil))
        guard let peer = inbound[side.peer] else { return }
        await peer.receiveFile(url, metadata: metadata)
        if duplicateDeliveries { await peer.receiveFile(url, metadata: metadata) }
    }

    private func record(from side: Side, channel: WatchTransportChannel, data: Data) {
        let envelope = try? WatchProtocolEnvelope.decode(data).get()
        deliveries.append(Delivery(from: side, channel: channel,
                                   kind: envelope?.kind, messageID: envelope?.messageID))
    }
}

/// One endpoint's view of the link. A struct so it can be handed to an actor-isolated coordinator
/// without any ownership question.
public struct WatchFakeTransport: WatchProtocolTransport {
    private let link: WatchFakeDuplexLink
    private let side: WatchFakeDuplexLink.Side

    init(link: WatchFakeDuplexLink, side: WatchFakeDuplexLink.Side) {
        self.link = link
        self.side = side
    }

    public func isReachable() async -> Bool { await link.currentlyReachable() }

    public func sendImmediate(_ data: Data) async throws -> Data {
        if await link.swallowsImmediateReplies() {
            // A phone that took the request and never answered. The caller's deadline ends this,
            // and cancelling the deadline group cancels the sleep, so nothing is left running.
            await link.recordUnanswered(from: side, data: data)
            try await Task.sleep(for: .seconds(3600))
            throw WatchProtocolFault(code: .requestTimedOut)
        }
        return try await link.sendImmediate(from: side, data: data)
    }

    public func updateApplicationContext(_ data: Data) async throws {
        await link.updateApplicationContext(from: side, data: data)
    }

    public func transferUserInfo(_ data: Data) async {
        await link.transferUserInfo(from: side, data: data)
    }

    public func transferFile(_ url: URL, metadata: [String: String]) async {
        await link.transferFile(from: side, url: url, metadata: metadata)
    }
}
