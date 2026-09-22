#if !os(watchOS)
import Foundation
import AVFoundation
import ParsoAudioStreaming
import Combine
import Network

extension AudioPlayer {
    // MARK: - Session / Remote

    func observeNetworkPath() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.pathIsExpensive = path.isExpensive
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    func resume() { seekToStartIfAtEnd(); player.play(); isPlaying = true; updateNowPlaying() }
    func pause() { player.pause(); isPlaying = false; updateNowPlaying() }

    /// AVPlayer never auto-rewinds: once an item plays to
    /// `AVPlayerItemDidPlayToEndTime` (the normal way a queue that isn't
    /// auto-extended — e.g. the Mood Starter Jamendo queue, which "Keep
    /// Playing" doesn't extend — reaches a real end with `repeatMode ==
    /// .off`), `currentItem` is left parked at its own duration. Calling
    /// `.play()` on an item already at its end is a no-op — real report:
    /// "the Jamendo track plays once, then pressing play again does
    /// nothing." Reproducible with any track whose queue actually ends
    /// (not just Jamendo), but Jamendo's non-extending queue is the
    /// common way to hit a genuine end in practice.
    func seekToStartIfAtEnd() {
        guard let item = player.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        if item.currentTime().seconds >= duration - 0.1 {
            player.seek(to: .zero)
            currentTime = 0
        }
    }

    func updateNowPlaying() {
        guard currentTrack != nil else {
            bridge.clearNowPlaying()
            return
        }
        persist(reason: .transportEvent)
        bridge.refreshNowPlaying(self)
    }

    func updateNowPlayingTime() {
        bridge.refreshNowPlayingTime(self)
    }

    // MARK: - Queue persistence (Fix 2)

    /// Persists the queue/position to the App Group on the same discrete events
    /// that publish now-playing info, so an intent-launched suspended app can
    /// rebuild the player instead of no-oping on an empty queue.
    internal func persistPlaybackState() {
        guard !isAmbient else { return }
        var ids: [Int64] = []
        var syncIDs: [String?] = []
        var currentIndex = 0
        for (position, row) in queue.enumerated() {
            guard let id = row.track.id, id > 0 else { continue }
            if position == index { currentIndex = ids.count }
            ids.append(id)
            syncIDs.append(row.track.syncID)
        }
        guard !ids.isEmpty else {
            PlaybackStateStore.clear()
            return
        }
        PlaybackStateStore.save(PlaybackStateSnapshot(
            trackIDs: ids,
            trackSyncIDs: syncIDs,
            currentIndex: currentIndex,
            elapsed: currentTime,
            isPlaying: isPlaying,
            savedAt: Date()
        ))
    }

    /// Single persistence funnel. Builds a snapshot, then delegates to the
    /// injectable `persistor` (admission policy + composite store).
    internal func persist(reason: PlaybackWriteReason) {
        guard !isAmbient else { return }
        guard !isRestoring else { return }

        var ids: [Int64] = []
        var syncIDs: [String?] = []
        var currentIndex = 0
        for (position, row) in queue.enumerated() {
            guard let id = row.track.id, id > 0 else { continue }
            if position == index { currentIndex = ids.count }
            ids.append(id)
            syncIDs.append(row.track.syncID)
        }

        if ids.isEmpty {
            persistor.save(candidate: nil, reason: reason)
            return
        }

        let candidate = PlaybackStateSnapshot(
            trackIDs: ids,
            trackSyncIDs: syncIDs,
            currentIndex: currentIndex,
            elapsed: currentTime,
            isPlaying: isPlaying,
            savedAt: Date()
        )

        persistor.save(candidate: candidate, reason: reason)
    }

    /// Called from the periodic tick while advancing. Throttled to ≥1 write/s.
    internal func persistTick() {
        guard isAdvancing else { return }
        let now = Date()
        guard now.timeIntervalSince(persistor.lastPersistAt) >= 1.0 else { return }
        persist(reason: .tick)
    }

    /// Exact, unthrottled persist for lifecycle events (app background /
    /// inactive). Admission still applies (G3: tick/background may not regress).
    public func persistNow() {
        persist(reason: .background)
    }

    /// Guarantees the persisted queue is restored before executing `action`, so
    /// cold-launch control surfaces (Siri intents, deep links, lock-screen
    /// commands) work from an empty-player state (F6).
    public func withRestoredQueue(_ action: @MainActor () -> Void) async {
        if queue.isEmpty, !isAmbient {
            await restorePersistedQueue()
        }
        action()
    }

    /// Rebuilds the queue from the persisted state (paused, no autoplay) when the
    /// player is empty. Runs at most once per process; concurrent callers await
    /// the same restore.
    public func restorePersistedQueue() async {
        if let restoreTask {
            await restoreTask.value
            return
        }
        let task = Task { await performQueueRestore() }
        restoreTask = task
        await task.value
    }

    /// Resets the once-per-process restore guard so tests can re-run
    /// `restorePersistedQueue()` without restarting the process.
    /// Also clears the restore task so the next call can retry (F5 retry).
    /// Also cancels any in-flight Keep Playing extension: `AudioPlayer` is a
    /// process-wide singleton shared across every test in a run, so a
    /// leaked, un-cancelled extension `Task` from one test could otherwise
    /// resolve during a completely unrelated later test and mutate its
    /// state (queue, `keepPlayingAutoAddedTrackIDs`, the fallback reason).
    internal func resetRestoreForTesting() {
        restoreTask = nil
        keepPlayingExtensionTask?.cancel()
        keepPlayingExtensionTask = nil
        keepPlayingExtensionInFlight = false
    }

    internal func performQueueRestore() async {
        guard queue.isEmpty, !isAmbient else { return }
        guard let saved = await persistor.loadBest(), !saved.trackIDs.isEmpty else { return }

        let plan = await QueueRestorePlanner.plan(
            saved: saved,
            resolveByID: { id in try? await LibraryStore.shared.trackRow(id: id) },
            resolveBySyncID: { syncID in try? await LibraryStore.shared.trackRow(syncID: syncID) }
        )

        guard let plan, !plan.rows.isEmpty, queue.isEmpty, !isAmbient else {
            // Retry: if nothing was restored, allow a second attempt later
            // (needed for post-CloudKit-reconcile second attempt, F8).
            restoreTask = nil
            return
        }

        isRestoring = true
        pendingRestoreSeek = nil

        queue = plan.rows
        index = plan.startIndex
        loadCurrent(autoplay: false)

        // Set currentTime to the seek target immediately so persist during the
        // seek window is accurate. Seek with zero tolerance for precision.
        currentTime = plan.seekTo
        if plan.seekTo > 0 {
            let cmTime = CMTime(seconds: plan.seekTo, preferredTimescale: 600)
            await player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            pendingRestoreSeek = plan.seekTo
        }

        isRestoring = false

        if pendingRestoreSeek == nil {
            persist(reason: .restoreCommit)
        }
    }
}
#endif
