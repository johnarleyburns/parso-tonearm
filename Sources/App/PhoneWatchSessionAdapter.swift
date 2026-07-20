import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
import TonearmCore

#if canImport(WatchConnectivity)

final class PhoneWatchSessionAdapter: NSObject, WCSessionDelegate, WatchSessionWriter {
    private let session: WCSession
    private var activationContinuation: CheckedContinuation<Bool, Never>?
    private var _catalogVersion: Int = 0

    override init() {
        self.session = WCSession.default
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
    }

    func displayState() -> WatchSessionDisplayState {
        guard WCSession.isSupported() else { return .unsupported }
        guard session.isPaired else { return .notInstalled }
        guard session.isWatchAppInstalled else { return .installedNotReachable }
        return session.isReachable ? .reachable : .installedNotReachable
    }

    func activate() async {
        guard WCSession.isSupported() else { return }
        guard session.activationState == .notActivated else { return }
        await withCheckedContinuation { continuation in
            activationContinuation = continuation
            session.activate()
        }
    }

    func sendCatalogFromStore(store: LibraryStore) async throws {
        let catalog = try await WatchCatalog.export(from: store)
        try await sendCatalog(catalog)
    }

    func transferFile(_ url: URL, metadata: WatchAudioMetadata) async throws {
        guard session.activationState == .activated else { return }
        session.transferFile(url, metadata: [
            "trackKey": metadata.trackKey,
            "bytes": "\(metadata.bytes)",
            "pinned": "\(metadata.pinned)",
            "catalogVersion": "\(metadata.catalogVersion)"
        ])
    }

    func sendUserInfo(_ info: [String: Any]) async throws {
        guard session.activationState == .activated else { return }
        session.transferUserInfo(info)
    }

    func sendCatalog(_ snapshot: WatchCatalogSnapshot) async throws {
        guard session.activationState == .activated else { return }
        _catalogVersion = snapshot.version
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("watch-catalog-\(snapshot.version).json")
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.transferFile(url, metadata: [
                "kind": WatchSyncMessageKind.catalog.rawValue,
                "version": "\(snapshot.version)"
            ])
            continuation.resume()
        }
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { await handleActivation(state: state, error: error) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        guard WCSession.isSupported() else { return }
        WCSession.default.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {}

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        Task { await handleMessage(message, replyHandler: replyHandler) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveUserInfo userInfo: [String: Any]) {
        Task { await handleUserInfo(userInfo) }
    }

    private func handleActivation(state: WCSessionActivationState, error: Error?) {
        activationContinuation?.resume(returning: state == .activated)
        activationContinuation = nil
    }

    private func handleMessage(_ message: [String: Any],
                               replyHandler: @escaping ([String: Any]) -> Void) {
        guard let kindStr = message["kind"] as? String,
              let kind = WatchSyncMessageKind(rawValue: kindStr) else {
            replyHandler(["error": "invalid message"])
            return
        }
        switch kind {
        case .fetchRequest, .fetchCancel, .resendCatalog:
            replyHandler(["ack": true])
        case .manifestReport:
            Task { await ingestManifestReport(message) }
            replyHandler(["ack": true])
        default:
            replyHandler(["error": "unexpected kind"])
        }
    }

    private func handleUserInfo(_ userInfo: [String: Any]) {
        guard let kindStr = userInfo["kind"] as? String,
              let kind = WatchSyncMessageKind(rawValue: kindStr) else { return }
        if kind == .manifestReport {
            Task { await ingestManifestReport(userInfo) }
        }
    }

    private func ingestManifestReport(_ info: [String: Any]) async {
        // Manifest reports are ingested by AppState via the database.
    }
}

#else

final class PhoneWatchSessionAdapter {
    func displayState() -> WatchSessionDisplayState { .unsupported }
    func activate() async {}
    func sendCatalogFromStore(store: LibraryStore) async throws {}
    func transferFile(_ url: URL, metadata: WatchAudioMetadata) async throws {}
    func sendUserInfo(_ info: [String: Any]) async throws {}
    func sendCatalog(_ snapshot: WatchCatalogSnapshot) async throws {}
}

#endif
