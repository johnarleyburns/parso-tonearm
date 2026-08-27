import Foundation

/// The transport seam. Everything above this line speaks typed envelopes; everything below it is a
/// WCSession adapter whose only job is to move `Data`.
///
/// §5 and the Phase 3 definition of done both turn on the same rule: *no dynamic dictionary parsing
/// exists outside adapters*. That is enforceable precisely because this protocol has no
/// `[String: Any]` in it. An adapter unwraps `WatchProtocolEnvelope.payloadKey` and hands over
/// `Data`; a coordinator never sees a dictionary at all.
public protocol WatchProtocolTransport: Sendable {
    func isReachable() async -> Bool
    /// `sendMessageData`. Throws `WatchProtocolFault` — `.phoneUnavailable` when unreachable,
    /// `.requestTimedOut` when the deadline passes, `.transferFailed` for anything else.
    func sendImmediate(_ data: Data) async throws -> Data
    /// `updateApplicationContext`. Coalesced by the system: only the newest survives.
    func updateApplicationContext(_ data: Data) async throws
    /// `transferUserInfo`. Durable and redelivered, which is why the ledger exists.
    func transferUserInfo(_ data: Data) async
    /// `transferFile`. Metadata is restricted to `String` values so it stays property-list-safe and
    /// cannot smuggle a payload the receiver would have to parse dynamically.
    func transferFile(_ url: URL, metadata: [String: String]) async
}

/// What a coordinator implements to receive from its peer. The adapter calls these; the
/// implementations are actors, so a delegate callback arriving on WatchConnectivity's private queue
/// is hopped onto the owning executor by the language rather than by a hand-rolled dispatch (C-02).
public protocol WatchProtocolInbound: AnyObject, Sendable {
    /// Returns the reply payload for a `sendMessageData`, or `nil` when there is nothing to reply
    /// with (the adapter then answers with an empty reply rather than leaving the peer hanging).
    func receiveImmediate(_ data: Data) async -> Data?
    func receiveApplicationContext(_ data: Data) async
    func receiveUserInfo(_ data: Data) async
    func receiveFile(_ url: URL, metadata: [String: String]) async
}

extension WatchProtocolInbound {
    public func receiveFile(_ url: URL, metadata: [String: String]) async {}
}

/// The session lifecycle an adapter drives. Separate from `WatchProtocolInbound` because it is the
/// only thing an adapter needs beyond delivery, and having it lets both adapters talk to a protocol
/// rather than downcasting to a concrete coordinator they should not know about.
public protocol WatchProtocolLifecycle: WatchProtocolInbound {
    /// `receivedContext` is whatever the session was already holding at activation — see C-01.
    func activate(reachable: Bool, receivedContext: Data?) async
    func reachabilityChanged(_ reachable: Bool) async
}

/// Deadlines. §5.2 fixes the immediate-command budget at eight seconds of UI time.
public enum WatchRequestDeadline {
    /// The §5.2 UI deadline for an immediate request.
    public static let immediate: Duration = .seconds(8)
}

/// Runs `operation` under a deadline and converts a timeout into the §5.5 code for it.
///
/// The losing branch is cancelled, not abandoned: a search that missed its deadline must stop
/// occupying the link, or a user typing quickly builds a backlog of requests nobody is waiting for.
public func withWatchRequestDeadline<Success: Sendable>(
    _ deadline: Duration = WatchRequestDeadline.immediate,
    operation: @escaping @Sendable () async throws -> Success
) async throws -> Success {
    try await withThrowingTaskGroup(of: Success.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: deadline)
            throw WatchProtocolFault(code: .requestTimedOut)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw WatchProtocolFault(code: .requestTimedOut)
        }
        return result
    }
}
