import Foundation
import Synchronization
import WatchConnectivity
import TonearmWatchProtocol

/// The watch's `WCSessionDelegate`. It owns the session and nothing else.
///
/// Every delegate callback does the same three things: unwrap the one payload key, hand the `Data`
/// to the endpoint, and get out of the way. It holds no state, makes no decisions, and knows no
/// message kinds — `WatchConnectivityCoordinator` does all of that, which is why the coordinator can
/// be tested end-to-end without a session existing at all.
///
/// `Sendable` without an escape hatch: the class is final, its only stored property is the endpoint
/// (itself an actor), and `WCSession.default` is read per call rather than stored.
public final class WatchProtocolSessionAdapter: NSObject, WCSessionDelegate, Sendable {
    private let endpoint: any WatchProtocolLifecycle

    public init(endpoint: any WatchProtocolLifecycle) {
        self.endpoint = endpoint
        super.init()
    }

    /// The transport half, for handing to the coordinator.
    public static var transport: WatchSessionTransport { WatchSessionTransport() }

    public func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - WCSessionDelegate

    public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                        error: (any Error)?) {
        // C-01: whatever context the session was already holding is delivered now, at activation,
        // rather than waited for. The coordinator decides what that cached state is worth.
        let context = WatchProtocolEnvelope.payloadData(in: session.receivedApplicationContext)
        let reachable = state == .activated && session.isReachable
        let endpoint = endpoint
        Task { await endpoint.activate(reachable: reachable, receivedContext: context) }
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        let endpoint = endpoint
        Task { await endpoint.reachabilityChanged(reachable) }
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
        Task {
            // An empty reply rather than none: the phone is holding a `sendMessageData` open, and
            // dropping it costs the peer its whole deadline.
            box.reply(await endpoint.receiveImmediate(messageData) ?? Data())
        }
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

    public func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file is deleted when this returns, so it is moved out of the inbox before the endpoint
        // is told about it. Everything past that point — checksum, install, dedupe — is Phase 5's.
        let metadata = (file.metadata ?? [:]).compactMapValues { $0 as? String }
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox-\(UUID().uuidString)")
            .appendingPathExtension(file.fileURL.pathExtension)
        do {
            try FileManager.default.moveItem(at: file.fileURL, to: staged)
        } catch {
            return
        }
        let endpoint = endpoint
        Task { await endpoint.receiveFile(staged, metadata: metadata) }
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
