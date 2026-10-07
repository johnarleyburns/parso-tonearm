import Foundation
import TonearmWatchProtocol
import TonearmWatchCore


/// Kept for the fan-out shape; reachability is now derived from the chrome in `WatchChromeObserver`
/// so the banner, the search scope and `model.phoneReachable` can never disagree (watch redesign
/// §6.4 — the "Your iPhone isn't reachable" while the phone was nearby bug).
final class WatchReachabilityObserver: WatchConnectivityObserver {
    init(model: WatchLibraryModel) {}
}

/// Projects the phone's per-track transfer progress onto the model so the Now Playing download ring
/// can close. State-only when the phone sends no fractions (an older phone) — E-13.
final class WatchDownloadStatusObserver: WatchConnectivityObserver {
    private let model: WatchLibraryModel

    init(model: WatchLibraryModel) {
        self.model = model
    }

    func didReceiveDownloadStatus(_ snapshot: WatchDownloadStatusSnapshot) async {
        await MainActor.run { model.setDownloadStatus(snapshot) }
    }
}

/// Drives the Phase 7 connection chrome (banner, disconnect haptic, A-08 prompt) and flips the
/// search presenter between connected and offline modes.
final class WatchChromeObserver: WatchConnectivityObserver {
    private let chrome: WatchConnectionChrome
    private let model: WatchLibraryModel
    private let search: WatchSearchPresenter

    init(chrome: WatchConnectionChrome, model: WatchLibraryModel, search: WatchSearchPresenter) {
        self.chrome = chrome
        self.model = model
        self.search = search
    }

    func connectionStateDidChange(_ state: WatchConnectionReducer.State,
                                  connectivity: WatchConnectivityState) async {
        await MainActor.run {
            chrome.apply(connectivity: connectivity)
            syncDerivedState()
        }
    }

    func didConfirmDisconnection() async {
        await MainActor.run {
            chrome.confirmedDisconnection()
            syncDerivedState()
        }
    }

    func didReconnect() async {
        await MainActor.run {
            chrome.reconnected()
            syncDerivedState()
        }
    }

    func didNegotiate(_ session: WatchNegotiatedSession) async {
        await MainActor.run {
            chrome.reconnected()
            syncDerivedState()
        }
    }

    func negotiationDidFail(_ fault: WatchProtocolFault) async {
        guard fault.code == .protocolUpgradeRequired else { return }
        await MainActor.run {
            chrome.markIncompatible()
            syncDerivedState()
        }
    }

    /// The one place reachability-derived state is written: the chrome's banner is the truth, and
    /// the search scope and `model.phoneReachable` follow it after every transition.
    @MainActor
    private func syncDerivedState() {
        let projection = WatchConnectionProjection(banner: chrome.banner)
        search.setMode(projection.searchMode)
        model.setPhoneReachable(projection.phoneReachable)
    }

    func pairedLibraryChangeRequiresConfirmation(current: WatchPairedLibraryID,
                                                 incoming: WatchPairedLibraryID) async {
        await MainActor.run {
            chrome.requestLibraryReplacement(current: current, incoming: incoming)
        }
    }
}
