#if canImport(WatchConnectivity)
import Foundation
import WatchConnectivity

/// The one place in the app where WatchConnectivity's dictionaries exist.
///
/// Both apps use this same file: the phone and the watch move bytes identically, and duplicating it
/// per platform would be two places for the payload key to drift. Everything platform-specific
/// lives in the two delegate adapters that own a session and hand their deliveries to an endpoint.
///
/// There is no protocol logic here on purpose. This type cannot decide, retry, deduplicate, or
/// interpret; it can only send `Data` and report why a send failed. That is what makes the Phase 3
/// definition of done — "no dynamic dictionary parsing exists outside adapters" — a property of the
/// code rather than a promise.
public struct WatchSessionTransport: WatchProtocolTransport {
    private let session: @Sendable () -> WCSession

    /// The session is fetched per call rather than stored: `WCSession` is not `Sendable`, and
    /// `WCSession.default` is a singleton, so holding one buys nothing and costs a concurrency
    /// escape hatch.
    public init(session: @escaping @Sendable () -> WCSession = { WCSession.default }) {
        self.session = session
    }

    public func isReachable() async -> Bool {
        let session = session()
        return session.activationState == .activated && session.isReachable
    }

    public func sendImmediate(_ data: Data) async throws -> Data {
        let session = session()
        guard session.activationState == .activated else {
            throw WatchProtocolFault(code: .phoneUnavailable)
        }
        guard session.isReachable else { throw WatchProtocolFault(code: .phoneUnavailable) }

        return try await withCheckedThrowingContinuation { continuation in
            // `sendMessageData` calls back on WatchConnectivity's own queue. The continuation is the
            // hop; no manual dispatch to main is needed, and adding one would only add latency to
            // the eight-second budget.
            session.sendMessageData(data, replyHandler: { reply in
                continuation.resume(returning: reply)
            }, errorHandler: { error in
                continuation.resume(throwing: Self.fault(for: error))
            })
        }
    }

    public func updateApplicationContext(_ data: Data) async throws {
        do {
            try session().updateApplicationContext(WatchProtocolEnvelope.dictionary(for: data))
        } catch {
            throw Self.fault(for: error)
        }
    }

    public func transferUserInfo(_ data: Data) async {
        // Queued by the system and redelivered until it lands, so there is nothing to report and
        // nothing to retry here. Duplicate delivery is the ledger's problem, by design.
        session().transferUserInfo(WatchProtocolEnvelope.dictionary(for: data))
    }

    public func transferFile(_ url: URL, metadata: [String: String]) async {
        session().transferFile(url, metadata: metadata)
    }

    /// Maps a WatchConnectivity error onto the §5.5 vocabulary. The error's own description never
    /// travels: A-06 forbids free text on the wire, and `NSError.localizedDescription` is exactly
    /// the kind of string that leaks a path or a title.
    static func fault(for error: any Error) -> WatchProtocolFault {
        guard let code = WCError.Code(rawValue: (error as NSError).code),
              (error as NSError).domain == WCErrorDomain else {
            return WatchProtocolFault(code: .transferFailed)
        }
        switch code {
        case .sessionNotActivated, .sessionInactive, .notReachable, .deviceNotPaired,
             .watchAppNotInstalled, .companionAppNotInstalled, .sessionMissingDelegate:
            return WatchProtocolFault(code: .phoneUnavailable)
        case .messageReplyTimedOut, .messageReplyFailed:
            return WatchProtocolFault(code: .requestTimedOut)
        case .insufficientSpace:
            return WatchProtocolFault(code: .insufficientWatchStorage)
        default:
            return WatchProtocolFault(code: .transferFailed)
        }
    }
}
#endif
