import Foundation
import TonearmWatchProtocol
import TonearmWatchCore

/// Fans one coordinator's observer callbacks out to several observers. The coordinator holds exactly
/// one observer; the watch app needs two — `WatchSyncActor` (turns the link into SwiftData truth)
/// and `WatchReachabilityObserver` (drives the connection chrome). Every method forwards verbatim.
actor WatchFanoutObserver: WatchConnectivityObserver {
    private let observers: [any WatchConnectivityObserver]

    init(_ observers: [any WatchConnectivityObserver]) {
        self.observers = observers
    }

    func connectionStateDidChange(_ state: WatchConnectionReducer.State,
                                  connectivity: WatchConnectivityState) async {
        for o in observers { await o.connectionStateDidChange(state, connectivity: connectivity) }
    }
    func didConfirmDisconnection() async {
        for o in observers { await o.didConfirmDisconnection() }
    }
    func didReconnect() async {
        for o in observers { await o.didReconnect() }
    }
    func didNegotiate(_ session: WatchNegotiatedSession) async {
        for o in observers { await o.didNegotiate(session) }
    }
    func negotiationDidFail(_ fault: WatchProtocolFault) async {
        for o in observers { await o.negotiationDidFail(fault) }
    }
    func didReceivePhonePlayback(_ snapshot: WatchPhonePlaybackSnapshot) async {
        for o in observers { await o.didReceivePhonePlayback(snapshot) }
    }
    func didReceiveDownloadStatus(_ snapshot: WatchDownloadStatusSnapshot) async {
        for o in observers { await o.didReceiveDownloadStatus(snapshot) }
    }
    func didReceiveDownloadRoots(_ payload: WatchSetDownloadRoots) async {
        for o in observers { await o.didReceiveDownloadRoots(payload) }
    }
    func didReceiveRemoveAssets(_ payload: WatchRemoveAssets) async {
        for o in observers { await o.didReceiveRemoveAssets(payload) }
    }
    func didReceiveAudioFile(at stagedURL: URL, metadata: [String: String]) async {
        // The staged file is consumed by the first observer that installs it; forward to each in
        // turn. In practice only the sync actor implements this.
        for o in observers { await o.didReceiveAudioFile(at: stagedURL, metadata: metadata) }
    }
    func phoneRequestedReconciliation(_ request: WatchReconciliationRequest) async {
        for o in observers { await o.phoneRequestedReconciliation(request) }
    }
    func pairedLibraryChangeRequiresConfirmation(current: WatchPairedLibraryID,
                                                 incoming: WatchPairedLibraryID) async {
        for o in observers { await o.pairedLibraryChangeRequiresConfirmation(current: current, incoming: incoming) }
    }
}

/// Projects the coordinator's connection state onto the `@MainActor` library model so the chrome can
/// show a live "iPhone connected / not reachable" state without any view touching `WCSession`.
final class WatchReachabilityObserver: WatchConnectivityObserver {
    private let model: WatchLibraryModel

    init(model: WatchLibraryModel) {
        self.model = model
    }

    func connectionStateDidChange(_ state: WatchConnectionReducer.State,
                                  connectivity: WatchConnectivityState) async {
        let reachable = connectivity == .connected
        await MainActor.run { model.setPhoneReachable(reachable) }
    }

    func didConfirmDisconnection() async {
        await MainActor.run { model.setPhoneReachable(false) }
    }

    func didReconnect() async {
        await MainActor.run { model.setPhoneReachable(true) }
    }
}
