import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore
import UIKit

extension AppState {
    // MARK: - Watch

    func startWatchTransferTick() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.watchRuntime.tick()
            }
        }
    }

    /// The pre-cutover name, kept because `WatchSettingsView` calls it. Now a reconcile nudge plus a
    /// pull of the runtime's derived state.
    func refreshWatchState() async {
        await watchRuntime.tick()
        refreshWatchStateFromRuntime()
    }

    func refreshWatchStateFromRuntime() {
        watchInstalledTrackIDs = watchRuntime.installedTrackIDs
        watchJobStates = watchRuntime.jobStateByTrackID
        watchTransferActiveCount = watchRuntime.activeJobCount
        watchFailedCount = watchRuntime.failedJobCount
        watchInstalledBytes = watchRuntime.installedBytes
        watchSessionState = watchRuntime.sessionDisplayState
        watchManagement = watchRuntime.management
    }

    private func watchTransferState(forID id: String) -> WatchTransferState? {
        switch watchJobStates[id] {
        case "queued", "resolving", "waitingForWiFi": return .queued
        case "transferring": return .sending
        case "sent": return .sent
        case "failed": return .failed
        default: return nil
        }
    }

    func watchGlyphState(for row: TrackRow) -> WatchGlyphState {
        let id = PhoneWatchID.track(row.track).rawValue
        return WatchGlyph.state(trackKey: id, manifest: watchInstalledTrackIDs,
                                transferState: watchTransferState(forID: id), errorText: nil,
                                sendingProgress: liveWatchTransferFraction(forID: id))
    }

    /// Sender-side byte progress for a track WatchConnectivity is transferring to the watch right
    /// now, read straight off the session so the Now Playing ring closes as it goes.
    func liveWatchTransferFraction(forID id: String) -> Double? {
        PhoneWatchProtocolAdapter.activeAudioTransferFractions()[id]
    }

    func watchAggregateState(for rows: [TrackRow]) -> (WatchGlyphState, Double) {
        let ids = rows.map { PhoneWatchID.track($0.track).rawValue }
        guard !ids.isEmpty else { return (.notOnWatch, 0) }
        let states = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            watchTransferState(forID: id).map { (id, $0) }
        })
        return WatchGlyph.aggregateState(trackKeys: ids, manifest: watchInstalledTrackIDs,
                                         transferStates: states, errorTexts: [:])
    }

    func downloadToWatch(rows: [TrackRow]) async {
        await watchRuntime.downloadTracks(rows)
        refreshWatchStateFromRuntime()
    }

    func removeFromWatch(rows: [TrackRow]) async {
        await watchRuntime.removeTracks(rows)
        refreshWatchStateFromRuntime()
    }

    func downloadAllToWatch(playlistId: Int64) async {
        await watchRuntime.downloadPlaylist(id: playlistId)
        refreshWatchStateFromRuntime()
    }

    func removeAllFromWatch() async {
        await watchRuntime.removeAll()
        refreshWatchStateFromRuntime()
    }

    /// The pre-cutover "re-send catalog" action is now "ask the watch to reconcile" — the watch
    /// pulls what it needs over the §5 protocol rather than being handed a mirror.
    func resendCatalogToWatch() async {
        await watchRuntime.requestReconciliation()
        refreshWatchStateFromRuntime()
    }

    // MARK: - Watch download management (Phase 8, P3/P4)

    func pauseWatchCollection(_ rootID: String) async {
        await watchRuntime.pauseRoot(rootID)
        refreshWatchStateFromRuntime()
    }

    func resumeWatchCollection(_ rootID: String) async {
        await watchRuntime.resumeRoot(rootID)
        refreshWatchStateFromRuntime()
    }

    func removeWatchCollection(_ rootID: String) async {
        await watchRuntime.removeRoot(rootID)
        refreshWatchStateFromRuntime()
    }

    func cancelWatchJob(_ requestID: String) async {
        await watchRuntime.cancelJob(requestID)
        refreshWatchStateFromRuntime()
    }

    func retryWatchJob(_ requestID: String) async {
        await watchRuntime.retryJob(requestID)
        refreshWatchStateFromRuntime()
    }

    func watchCollectionDetail(_ rootID: String) async -> PhoneWatchManagementPresenter.CollectionDetail? {
        await watchRuntime.collectionDetail(rootID)
    }

    /// Persist phone-authored art as a derivative-backed custom binding and nudge the active watch
    /// roots so the same desired-download reconciliation schedules its bytes.
}
