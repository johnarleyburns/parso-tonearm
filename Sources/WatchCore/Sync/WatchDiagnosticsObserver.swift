import Foundation
import TonearmWatchProtocol

/// §12 — a `WatchConnectivityObserver` that does nothing but record privacy-safe diagnostics for the
/// link events the other observers act on. It is added to the fanout alongside the sync actor and
/// the chrome observer, so the request/install/manifest recorders in `WatchConnectivityCoordinator`
/// and `WatchSyncActor` are joined here by activation, transfer-state, and route-event coverage —
/// the full §12 signal set, none of it carrying a title, URL, path, or id.
public actor WatchDiagnosticsObserver: WatchConnectivityObserver {
    private let diagnostics: WatchDiagnosticsRecorder

    public init(diagnostics: WatchDiagnosticsRecorder) {
        self.diagnostics = diagnostics
    }

    public func connectionStateDidChange(_ state: WatchConnectionReducer.State,
                                         connectivity: WatchConnectivityState) async {
        await diagnostics.record(.routeEvent, connectivity.rawValue)
    }

    public func didNegotiate(_ session: WatchNegotiatedSession) async {
        await diagnostics.record(.activation, "negotiated")
    }

    public func negotiationDidFail(_ fault: WatchProtocolFault) async {
        await diagnostics.record(.activation, fault.code.rawValue)
    }

    public func didReceiveDownloadRoots(_ payload: WatchSetDownloadRoots) async {
        await diagnostics.record(.transferState, "rootsReceived",
                                 count: payload.desiredTrackIDs.count)
    }

    public func didReceiveDownloadStatus(_ snapshot: WatchDownloadStatusSnapshot) async {
        let code = snapshot.failedCount > 0 ? "failing"
            : snapshot.isIdle ? "idle" : "active"
        await diagnostics.record(.transferState, code, count: snapshot.readyCount)
    }

    public func didReceiveRemoveAssets(_ payload: WatchRemoveAssets) async {
        await diagnostics.record(.transferState, "removeAssets", count: payload.trackIDs.count)
    }

    public func phoneRequestedReconciliation(_ request: WatchReconciliationRequest) async {
        await diagnostics.record(.manifestConvergence, "reconcileRequested")
    }
}
