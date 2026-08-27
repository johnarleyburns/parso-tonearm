import Foundation
import WatchConnectivity
import TonearmWatchProtocol

final class WatchSessionAdapter: NSObject, @unchecked Sendable, WCSessionDelegate, ObservableObject {
    static let shared = WatchSessionAdapter()
    private let session: WCSession

    /// Live connection state to the paired iPhone, published so the UI can show
    /// whether the phone is currently reachable for fetches/streaming assistance.
    @Published private(set) var isReachable = false
    @Published private(set) var isActivated = false

    var onCatalogReceived: ((WatchCatalogSnapshot) -> Void)?
    var onAudioReceived: ((URL, WatchAudioMetadata) -> Void)?
    var onDeleteTracks: (([String]) -> Void)?

    override init() {
        self.session = WCSession.default
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
    }

    func displayState() -> WatchSessionDisplayState {
        guard WCSession.isSupported() else { return .unsupported }
        return session.isReachable ? .reachable : .installedNotReachable
    }

    func activate() {
        guard WCSession.isSupported(), session.activationState == .notActivated else { return }
        session.activate()
    }

    private func refreshConnectionState() {
        let reachable = WCSession.isSupported() && session.isReachable
        let activated = WCSession.isSupported() && session.activationState == .activated
        Task { @MainActor in
            self.isReachable = reachable
            self.isActivated = activated
        }
    }

    // MARK: - WCSessionDelegate

    @discardableResult
    func sendFetchRequest(trackKey: String) -> Bool {
        guard session.isReachable else { return false }
        session.sendMessage(["kind": WatchSyncMessageKind.fetchRequest.rawValue, "trackKey": trackKey],
                            replyHandler: nil) { _ in }
        return true
    }

    func sendCancelFetch(trackKey: String) {
        guard session.isReachable else { return }
        session.sendMessage(["kind": WatchSyncMessageKind.fetchCancel.rawValue, "trackKey": trackKey],
                            replyHandler: nil) { _ in }
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        refreshConnectionState()
    }

    // These callbacks are required when the shared source is compiled against
    // the iOS WatchConnectivity SDK. watchOS marks them unavailable because
    // its session lifecycle does not deactivate in the same way.
    #if !os(watchOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    func session(_ session: WCSession,
                 didReceive file: WCSessionFile) {
        guard let metadata = file.metadata else { return }
        if let kindStr = metadata["kind"] as? String,
           kindStr == WatchSyncMessageKind.catalog.rawValue {
            handleCatalogFile(file)
        } else if metadata["trackKey"] is String {
            handleAudioFile(file, metadata: metadata)
        }
    }

    func session(_ session: WCSession,
                 didReceiveUserInfo userInfo: [String: Any]) {
        if let kindStr = userInfo["kind"] as? String,
           let kind = WatchSyncMessageKind(rawValue: kindStr),
           kind == .deleteTracks,
           let keys = userInfo["trackKeys"] as? [String] {
            onDeleteTracks?(keys)
        }
    }

    func session(_ session: WCSession,
                 didReceiveMessage message: [String: Any]) {
        // Messages are handled by iPhone side
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        refreshConnectionState()
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {}

    // MARK: - Private

    private func handleCatalogFile(_ file: WCSessionFile) {
        guard let data = try? Data(contentsOf: file.fileURL),
              let catalog = try? JSONDecoder().decode(WatchCatalogSnapshot.self, from: data) else { return }
        onCatalogReceived?(catalog)
    }

    private func handleAudioFile(_ file: WCSessionFile, metadata: [String: Any]) {
        guard let trackKey = metadata["trackKey"] as? String,
              let bytesStr = metadata["bytes"] as? String,
              let bytes = Int64(bytesStr),
              let pinnedStr = metadata["pinned"] as? String,
              let pinned = Bool(pinnedStr),
              let versionStr = metadata["catalogVersion"] as? String,
              let version = Int(versionStr) else { return }
        let meta = WatchAudioMetadata(trackKey: trackKey, bytes: bytes,
                                       pinned: pinned, catalogVersion: version)
        onAudioReceived?(file.fileURL, meta)
    }
}
