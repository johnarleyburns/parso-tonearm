import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore

/// General library UI (row glyphs, Now Playing) calls these unconditionally
/// regardless of platform, so they stay outside the `#if os(iOS)` block
/// below — on Mac there's simply never anything on a watch (no paired watch),
/// which
/// `WatchGlyphState.notOnWatch` already expresses honestly. `WatchGlyphState`/
/// `WatchGlyph`/`PhoneWatchID`/`WatchTransferState` all live in the portable
/// `Sources/WatchSync`/`Sources/WatchProtocol` packages, so referencing them
/// here needs no platform branch of their own.
extension AppState {
    private func watchTransferState(forID id: String) -> WatchTransferState? {
        #if os(macOS)
        nil
        #else
        switch watchJobStates[id] {
        case "queued", "resolving", "waitingForWiFi": return .queued
        case "transferring": return .sending
        case "sent": return .sent
        case "failed": return .failed
        default: return nil
        }
        #endif
    }

    func watchGlyphState(for row: TrackRow) -> WatchGlyphState {
        #if os(macOS)
        .notOnWatch
        #else
        let id = PhoneWatchID.track(row.track).rawValue
        return WatchGlyph.state(trackKey: id, manifest: watchInstalledTrackIDs,
                                transferState: watchTransferState(forID: id), errorText: nil,
                                sendingProgress: liveWatchTransferFraction(forID: id))
        #endif
    }

    /// Sender-side byte progress for a track WatchConnectivity is transferring to the watch right
    /// now, read straight off the session so the Now Playing ring closes as it goes.
    func liveWatchTransferFraction(forID id: String) -> Double? {
        #if os(macOS)
        nil
        #else
        PhoneWatchProtocolAdapter.activeAudioTransferFractions()[id]
        #endif
    }

    func watchAggregateState(for rows: [TrackRow]) -> (WatchGlyphState, Double) {
        #if os(macOS)
        (.notOnWatch, 0)
        #else
        let ids = rows.map { PhoneWatchID.track($0.track).rawValue }
        guard !ids.isEmpty else { return (.notOnWatch, 0) }
        let states = Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            watchTransferState(forID: id).map { (id, $0) }
        })
        return WatchGlyph.aggregateState(trackKeys: ids, manifest: watchInstalledTrackIDs,
                                         transferStates: states, errorTexts: [:])
        #endif
    }
}

#if os(iOS)
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
        let wasReachable = watchSessionState == .reachable
        watchInstalledTrackIDs = watchRuntime.installedTrackIDs
        watchJobStates = watchRuntime.jobStateByTrackID
        watchTransferActiveCount = watchRuntime.activeJobCount
        watchFailedCount = watchRuntime.failedJobCount
        watchInstalledBytes = watchRuntime.installedBytes
        watchSessionState = watchRuntime.sessionDisplayState
        if !wasReachable && watchSessionState == .reachable {
            ToastCenter.shared.success("Apple Watch connected", icon: "applewatch", tag: "watch.connection")
        }
        watchManagement = watchRuntime.management
    }

    @discardableResult
    func downloadToWatch(rows: [TrackRow]) async -> String? {
        var savedRows: [TrackRow] = []
        for row in rows {
            if row.id < 0 {
                guard let persisted = await persistRemoteTrack(row), persisted.id >= 0 else {
                    ToastCenter.shared.error("Couldn't save this track for Apple Watch", tag: "dl.watch")
                    return nil
                }
                savedRows.append(persisted)
            } else {
                savedRows.append(row)
            }
        }
        do {
            try await watchRuntime.downloadTracks(savedRows)
        } catch {
            ToastCenter.shared.error("Couldn't queue the Apple Watch download", tag: "dl.watch")
            refreshWatchStateFromRuntime()
            return nil
        }
        refreshWatchStateFromRuntime()
        ToastCenter.shared.info("Queued for Apple Watch", tag: "dl.watch")
        return savedRows.first.map { PhoneWatchID.track($0.track).rawValue }
    }

    func removeFromWatch(rows: [TrackRow]) async {
        await watchRuntime.removeTracks(rows)
        refreshWatchStateFromRuntime()
    }

    func removeTrackFromWatch(_ id: String) async {
        await watchRuntime.removeTrackFromWatch(id)
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

    func syncWatchMetadata() async -> WatchMetadataSyncResult {
        let result = await watchRuntime.synchronizeMetadata()
        refreshWatchStateFromRuntime()
        return result
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
#endif
