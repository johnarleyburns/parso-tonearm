import Foundation
import TonearmWatchProtocol

/// What the watch app learns from the link. Every method has a no-op default, so Phase 5's download
/// installer and Phase 7's UI each implement only the handful they care about instead of carrying a
/// dozen empty stubs.
///
/// It is `async` throughout because every implementation is going to be an actor or `@MainActor`
/// type, and a synchronous callback would force each one to spawn an unstructured `Task` — which is
/// exactly the ordering hazard §5.4 spends a section on.
public protocol WatchConnectivityObserver: AnyObject, Sendable {
    func connectionStateDidChange(_ state: WatchConnectionReducer.State,
                                  connectivity: WatchConnectivityState) async
    /// C-09: fired once per confirmed outage, after the grace period, never on a blip.
    func didConfirmDisconnection() async
    func didReconnect() async
    func didNegotiate(_ session: WatchNegotiatedSession) async
    func negotiationDidFail(_ fault: WatchProtocolFault) async
    func didReceivePhonePlayback(_ snapshot: WatchPhonePlaybackSnapshot) async
    func didReceiveDownloadStatus(_ snapshot: WatchDownloadStatusSnapshot) async
    func didReceiveDownloadRoots(_ payload: WatchSetDownloadRoots) async
    func didReceiveRemoveAssets(_ payload: WatchRemoveAssets) async
    /// §5.2 `transferFile`: one audio delivery has been staged by the transport adapter and is the
    /// observer's to install (§8.3) or defer. `stagedURL` is consumed by the implementation.
    func didReceiveAudioFile(at stagedURL: URL, metadata: [String: String]) async
    func phoneRequestedReconciliation(_ request: WatchReconciliationRequest) async
    /// A-08: the phone's library identity differs from the one this watch is bound to. Nothing has
    /// been applied; the app must ask the user before `confirmPairedLibraryReplacement()`.
    func pairedLibraryChangeRequiresConfirmation(current: WatchPairedLibraryID,
                                                 incoming: WatchPairedLibraryID) async
}

extension WatchConnectivityObserver {
    public func connectionStateDidChange(_ state: WatchConnectionReducer.State,
                                         connectivity: WatchConnectivityState) async {}
    public func didConfirmDisconnection() async {}
    public func didReconnect() async {}
    public func didNegotiate(_ session: WatchNegotiatedSession) async {}
    public func negotiationDidFail(_ fault: WatchProtocolFault) async {}
    public func didReceivePhonePlayback(_ snapshot: WatchPhonePlaybackSnapshot) async {}
    public func didReceiveDownloadStatus(_ snapshot: WatchDownloadStatusSnapshot) async {}
    public func didReceiveDownloadRoots(_ payload: WatchSetDownloadRoots) async {}
    public func didReceiveRemoveAssets(_ payload: WatchRemoveAssets) async {}
    public func didReceiveAudioFile(at stagedURL: URL, metadata: [String: String]) async {}
    public func phoneRequestedReconciliation(_ request: WatchReconciliationRequest) async {}
    public func pairedLibraryChangeRequiresConfirmation(current: WatchPairedLibraryID,
                                                        incoming: WatchPairedLibraryID) async {}
}

/// The watch's persisted view of who it is bound to and how far it has caught up. A seam rather than
/// a direct SwiftData dependency, because the coordinator has to work before the store is open — a
/// `storeRecovered` launch still needs to negotiate and ask the phone to reconcile.
public protocol WatchSyncStateStore: Sendable {
    func loadPairedLibraryID() async -> WatchPairedLibraryID?
    func savePairedLibraryID(_ id: WatchPairedLibraryID) async
    func loadLastAppliedPhoneRevision() async -> Int64
    func saveLastAppliedPhoneRevision(_ revision: Int64) async
}

/// Deterministic tests and first launch.
public actor WatchInMemorySyncStateStore: WatchSyncStateStore {
    private var pairedLibraryID: WatchPairedLibraryID?
    private var lastAppliedPhoneRevision: Int64

    public init(pairedLibraryID: WatchPairedLibraryID? = nil, lastAppliedPhoneRevision: Int64 = 0) {
        self.pairedLibraryID = pairedLibraryID
        self.lastAppliedPhoneRevision = lastAppliedPhoneRevision
    }

    public func loadPairedLibraryID() async -> WatchPairedLibraryID? { pairedLibraryID }
    public func savePairedLibraryID(_ id: WatchPairedLibraryID) async { pairedLibraryID = id }
    public func loadLastAppliedPhoneRevision() async -> Int64 { lastAppliedPhoneRevision }
    public func saveLastAppliedPhoneRevision(_ revision: Int64) async { lastAppliedPhoneRevision = revision }
}
