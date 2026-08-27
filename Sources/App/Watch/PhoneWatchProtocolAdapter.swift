import Foundation
import Synchronization
import TonearmCore
import TonearmWatchProtocol
import WatchConnectivity

/// The phone's `WCSessionDelegate` for the §5 protocol. The mirror of the watch's adapter, and just
/// as empty: unwrap one key, hand over `Data`, return.
///
/// iOS adds the two lifecycle callbacks watchOS does not have. Reactivating on `sessionDidDeactivate`
/// is required rather than optional — a phone paired to a second watch never delivers anything again
/// if that call is skipped.
public final class PhoneWatchProtocolAdapter: NSObject, WCSessionDelegate, Sendable {
    private let endpoint: any WatchProtocolLifecycle

    public init(endpoint: any WatchProtocolLifecycle) {
        self.endpoint = endpoint
        super.init()
    }

    public static var transport: WatchSessionTransport { WatchSessionTransport() }

    /// A point-in-time read of the pairing/installation/reachability of the default session, for the
    /// Phase 8 Settings › Apple Watch surface. `WCSession.isPaired` / `isWatchAppInstalled` are
    /// iOS-only API, which is why this lives here rather than in the host-testable core.
    public struct Capability: Sendable, Equatable {
        public var isSupported: Bool
        public var isPaired: Bool
        public var isWatchAppInstalled: Bool
        public var isReachable: Bool
    }

    public static func currentCapability() -> Capability {
        guard WCSession.isSupported() else {
            return Capability(isSupported: false, isPaired: false, isWatchAppInstalled: false, isReachable: false)
        }
        let session = WCSession.default
        return Capability(isSupported: true, isPaired: session.isPaired,
                          isWatchAppInstalled: session.isWatchAppInstalled, isReachable: session.isReachable)
    }

    public func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - WCSessionDelegate

    public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                        error: (any Error)?) {
        let reachable = state == .activated && session.isReachable
        let endpoint = endpoint
        Task { await endpoint.activate(reachable: reachable, receivedContext: nil) }
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        let endpoint = endpoint
        Task { await endpoint.reachabilityChanged(reachable) }
    }

    public func sessionDidBecomeInactive(_ session: WCSession) {}

    public func sessionDidDeactivate(_ session: WCSession) {
        // The user switched to a different watch. Without this the session stays dead.
        WCSession.default.activate()
    }

    public func session(_ session: WCSession, didReceiveMessageData messageData: Data,
                        replyHandler: @escaping (Data) -> Void) {
        let endpoint = endpoint
        // WatchConnectivity's reply handler predates `Sendable`: it is documented as callable
        // from any queue, exactly once, and the compiler has no way to see that. `nonisolated(unsafe)`
        // states it for this one binding — the narrowest possible scope — and the box below turns the
        // "exactly once" half from a documented rule into an enforced one.
        nonisolated(unsafe) let handler = replyHandler
        let box = WatchReplyHandlerBox(handler)
        Task { box.reply(await endpoint.receiveImmediate(messageData) ?? Data()) }
    }

    public func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        let endpoint = endpoint
        Task { _ = await endpoint.receiveImmediate(messageData) }
    }

    public func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let data = WatchProtocolEnvelope.payloadData(in: context) else { return }
        let endpoint = endpoint
        Task { await endpoint.receiveApplicationContext(data) }
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = WatchProtocolEnvelope.payloadData(in: userInfo) else { return }
        let endpoint = endpoint
        Task { await endpoint.receiveUserInfo(data) }
    }
}

/// WatchConnectivity hands back a reply handler that is not `Sendable`, must be called from
/// whatever executor finishes the work, and — the part that actually bites — must be called exactly
/// once. `Mutex` answers all three: it is the standard library's checked carrier for shared mutable
/// state, and clearing the handler under the lock makes a double reply impossible rather than
/// merely unlikely. This is deliberately not an `@unchecked Sendable` box; the invariant is enforced.
private final class WatchReplyHandlerBox: Sendable {
    private let handler: Mutex<((Data) -> Void)?>

    /// `sending`, because the handler is transferred out of the delegate callback and never
    /// touched there again — which is exactly the guarantee the compiler needs and we can give.
    init(_ handler: sending @escaping (Data) -> Void) { self.handler = Mutex(handler) }

    func reply(_ data: Data) {
        handler.withLock { pending in
            pending?(data)
            pending = nil
        }
    }
}
