#if !os(watchOS)
import Foundation
import AVFoundation
import OSLog

private let mixDecksLog = Logger(subsystem: "guru.parso.tonearm", category: "MixDecks")

/// Smart transitions play on the mix decks (MixDeckPlayer), the app's one
/// planner and mixer for blends: the approved dj2 blends need both tracks on one
/// sample clock with a crossover in their path, which two AVPlayers can't give.
/// Everything else about the queue (index, Now Playing, persistence, Keep
/// Playing) stays in AudioPlayer. AVPlayer plays queues without smart
/// transitions, with the user's plain crossfade at most.
extension AudioPlayer: MixDeckHost {
    /// Whether the current queue plays on the mix decks: mixes, every queue when
    /// "Use for everything" is on, and auditions.
    var wantsMixDecks: Bool {
        guard !isAmbient else { return false }
        if plainRestoreAfterRecovery, isRestoring { return false }
        if auditionRequested || isMixQueue { return true }
        guard smartTransitionsEnabled else { return false }
        return UserDefaults.standard.bool(forKey: "smartTransitionsEverywhere")
    }

    /// A Build a Mix queue is the best DJ mix we can make: it always blends
    /// (double drop, bass swap, else a phrase cut), whatever the Smart
    /// transitions settings say. Other queues blend when those are on.
    var isMixQueue: Bool {
        if case .mix = queueSource { return true }
        return false
    }

    var mixDecksBlend: Bool { smartTransitionsEnabled || isMixQueue }

    /// Loads the current track onto the mix decks. False when the decks can't
    /// be created, and the caller plays it on AVPlayer instead.
    func loadCurrentOnMixDecks(row: TrackRow, autoplay: Bool) -> Bool {
        // An edge denied moments ago is not retried: that would re-enter the unsafe backend.
        if let token = liveMixFallbackToken {
            liveMixFallbackToken = nil
            if token.generation == transitionExecution.generation,
               token.occurrence == mixDecksOccurrence(at: index) { return false }
        }
        // Nothing is decoded (not even on queue restore, paused) unless the whole-track mixer is admitted.
        let admission = mixDecksAdmission(index: index, outgoing: nil)
        guard admission == .allowLiveMix else {
            mixDecksLog.notice("live mix not admitted for current track, playing normally: \(String(describing: admission), privacy: .public)")
            releaseLiveMixReservation()
            liveMixFallback = TransitionFallbackStatus(decision: admission)
            return false
        }
        liveMixFallback = nil
        // Durable sentinel first: a kill during the decode or mixer start must be attributable.
        guard transitionSafety.enter(.startingCurrent) else {
            mixDecksLog.error("mix safety journal unavailable, playing normally")
            return false
        }
        if mixDecks == nil {
            do {
                mixDecks = try MixDeckPlayer(host: self)
            } catch {
                transitionSafety.resolve(.safeFallback)
                mixDecksLog.error("mix decks unavailable, playing on AVPlayer: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        guard let mixDecks else { transitionSafety.resolve(.safeFallback); return false }
        mixDecks.safety = transitionSafety
        cancelCrossfade(resetVolume: true)
        shutdownLoaders()
        dropPreloadedNext()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isOutgoingTransitionTailAudible = false
        deferredTransitionPlan = nil
        transitionPlan = nil

        mixDecks.volume = outputLevel
        mixDecks.blendsEnabled = mixDecksBlend
        currentTime = 0
        duration = row.track.durationSec ?? 0
        isPlaying = autoplay
        mixDecks.start(index: index, at: 0, autoplay: autoplay)
        updateNowPlaying()
        prefetchNext()
        if autoplay, let trackId = row.track.id {
            Task { try? await LibraryStore.shared.recordPlay(trackId: trackId) }
        }
        maybeExtendKeepPlayingQueue()
        return true
    }

    /// Resumes the decks, restarting the current track when it had played out.
    func resumeMixDecks(_ mixDecks: MixDeckPlayer) {
        if mixDecks.current == nil || mixDecks.hasReachedEnd {
            mixDecks.start(index: index, at: 0, autoplay: true)
        } else {
            mixDecks.resume()
        }
    }

    func stopMixDecks() {
        releaseLiveMixReservation()
        liveMixFallbackToken = nil
        guard let mixDecks else { return }
        mixDecks.stop()
        self.mixDecks = nil
        isOutgoingTransitionTailAudible = false
        deferredTransitionPlan = nil
        transitionPlan = nil
        transitionPrepState = .ready
    }

    // MARK: - Execution snapshots

    /// Keeps `queueOccurrences` parallel to `queue` after any edit, matching surviving rows in
    /// order so reorder/delete/insert keep identities and duplicates stay distinct. A change of
    /// identities advances the generation, which cancels edges that are no longer adjacent.
    func reconcileQueueOccurrences(old: [TrackRow]) {
        var oldOccurrences = queueOccurrences
        if oldOccurrences.count != old.count { oldOccurrences = old.map { _ in QueueOccurrenceID() } }
        var used = Set<Int>()
        var cursor = 0
        var result: [QueueOccurrenceID] = []
        for row in queue {
            let match = (cursor..<old.count).first { !used.contains($0) && old[$0].track.id == row.track.id }
                ?? old.indices.first { !used.contains($0) && old[$0].track.id == row.track.id }
            if let match {
                used.insert(match)
                cursor = match + 1
                result.append(oldOccurrences[match])
            } else {
                result.append(QueueOccurrenceID())
            }
        }
        guard result != queueOccurrences || oldOccurrences.count != queueOccurrences.count else { return }
        queueOccurrences = result
        transitionExecution.advanceGeneration(order: result, loops: repeatMode == .all)
        pruneNoBlendEdges()
    }

    /// Drops "play without blend" requests for pairs that are no longer adjacent in the queue.
    private func pruneNoBlendEdges() {
        guard !noBlendEdges.isEmpty else { return }
        var adjacent = Set<TransitionEdgeKey>()
        for i in queueOccurrences.indices {
            let next = i + 1 < queueOccurrences.count ? i + 1 : (repeatMode == .all ? 0 : nil)
            if let next { adjacent.insert(TransitionEdgeKey(from: queueOccurrences[i], to: queueOccurrences[next])) }
        }
        noBlendEdges.formIntersection(adjacent)
    }

    /// Makes exactly the edge `key` play sequentially. False when it is not an adjacent queue
    /// pair or is already audible; no other edge is touched.
    @discardableResult
    public func playWithoutBlend(_ key: TransitionEdgeKey) -> Bool {
        guard let from = queueOccurrences.firstIndex(of: key.from), let to = mixDecksSuccessor(of: from),
              queueOccurrences[to] == key.to else { return false }
        if let phase = transitionExecution.snapshot(for: key)?.phase, phase == .overlapping || phase == .handedOff {
            return false // already audible: a blend in progress is never torn out
        }
        noBlendEdges.insert(key)
        if from == index { mixDecks?.upcomingChanged() } // replaces a blend that has not started
        return true
    }

    /// Retries an edge the renderer denied or cancelled. Only an edge leaving the current track
    /// can be retried now; the others are retried by the scheduler when they become next.
    @discardableResult
    public func retryTransition(_ key: TransitionEdgeKey) -> Bool {
        guard let from = queueOccurrences.firstIndex(of: key.from), let to = mixDecksSuccessor(of: from),
              queueOccurrences[to] == key.to, transitionExecution.snapshot(for: key)?.isTerminal == true else { return false }
        noBlendEdges.remove(key)
        liveMixFallbackToken = nil
        if from == index {
            mixDecks?.upcomingChanged()
            preloadNextItem(allowingMixDecks: true)
        }
        return true
    }

    private func mixDecksSuccessor(of slot: Int) -> Int? {
        slot + 1 < queueOccurrences.count ? slot + 1 : (repeatMode == .all && queueOccurrences.count > 1 ? 0 : nil)
    }

    /// A replacement queue shares no identities with the old one, even for the same tracks.
    func replaceQueueOccurrences() {
        transitionExecution.cancelAll(reason: .replaced)
        noBlendEdges = []
        queueOccurrences = queue.map { _ in QueueOccurrenceID() }
        transitionExecution.advanceGeneration(order: queueOccurrences, loops: repeatMode == .all)
    }

    private func mixDecksEdgeKey(from: Int, to: Int) -> TransitionEdgeKey? {
        guard let a = mixDecksOccurrence(at: from), let b = mixDecksOccurrence(at: to) else { return nil }
        return TransitionEdgeKey(from: a, to: b)
    }

    var mixDecksQueueGeneration: Int { transitionExecution.generation }

    func mixDecksOccurrence(at index: Int) -> QueueOccurrenceID? {
        queueOccurrences.indices.contains(index) ? queueOccurrences[index] : nil
    }

    func mixDecksExecution(_ event: MixDeckExecutionEvent) {
        switch event {
        case let .scheduled(key, generation, requested, planned, executed, reason, start, end, handoff, rate):
            transitionExecution.record(key, generation: generation,
                                       .scheduled(requested: requested, planned: planned, executed: executed,
                                                  readiness: .ready, reason: reason, overlapStart: start,
                                                  overlapEnd: end, handoff: handoff, sampleRate: rate))
        case let .overlapBegan(key, generation, frame):
            transitionExecution.record(key, generation: generation, .overlapBegan(atFrame: frame))
        case let .handedOff(key, generation, frame):
            transitionExecution.record(key, generation: generation, .handedOff(atFrame: frame))
        case let .outgoingFinished(key, generation, frame):
            transitionExecution.outgoingFinished(key, generation: generation, atFrame: frame)
        case .reset(let reason):
            transitionExecution.cancelAll(reason: reason)
        }
    }

    /// The execution snapshot for the edge leaving queue slot `slot`, nil when none was emitted.
    public func transitionExecutionSnapshot(afterQueueIndex slot: Int) -> TransitionExecutionSnapshot? {
        guard queueOccurrences.indices.contains(slot) else { return nil }
        let nextSlot = slot + 1 < queueOccurrences.count ? slot + 1 : (repeatMode == .all ? 0 : nil)
        guard let nextSlot else { return nil }
        return transitionExecution.snapshot(for: TransitionEdgeKey(from: queueOccurrences[slot], to: queueOccurrences[nextSlot]))
    }

    // MARK: - MixDeckHost

    var mixDecksCurrentIndex: Int { index }

    func mixDecksUpcomingIndex(after current: Int) -> Int? {
        guard !queue.isEmpty, repeatMode != .one, !sleepAtEndOfTrack else { return nil }
        let next: Int
        if current < queue.count - 1 {
            next = current + 1
        } else if repeatMode == .all, queue.count > 1 {
            next = 0
        } else {
            return nil
        }
        if let from = mixDecksOccurrence(at: current), let to = mixDecksOccurrence(at: next),
           noBlendEdges.contains(TransitionEdgeKey(from: from, to: to)) { return nil }
        // An unplayable or Wi-Fi-only next track isn't blended into; when the
        // current one ends, next() skips it as it would without the decks.
        guard let asset = queue[next].asset, asset.unsupportedReason == nil,
              playbackDecision(for: asset) != .skipWiFiOnly else { return nil }
        return next
    }

    func mixDecksEdge(from: Int, to: Int) -> MixDeckEdge {
        guard queue.indices.contains(from), queue.indices.contains(to) else { return .blend }
        if CrossfadeCurve.suppressesForGaplessAlbum(current: CrossfadeCurve.AlbumContinuity(row: queue[from]),
                                                    next: CrossfadeCurve.AlbumContinuity(row: queue[to])) {
            return .gapless
        }
        if case .mix(let mix) = queueSource,
           mix.transitionPlans.contains(where: {
               $0.fromTrackID == queue[from].track.id && $0.toTrackID == queue[to].track.id
                   && $0.style == .plainCrossfade
           }) {
            return .fade
        }
        return .blend
    }

    func mixDecksTrack(at index: Int) -> (trackID: Int64, source: MixTrackSource, bpm: Double?)? {
        guard queue.indices.contains(index), let id = queue[index].track.id,
              let asset = queue[index].asset, let source = mixTrackSource(for: asset) else { return nil }
        return (id, source, nil)
    }

    func mixDecksDidAdvance(to scheduledIndex: Int, trackID: Int64, duration trackDuration: Double) -> Int {
        // The queue may have been edited since the blend was scheduled: find the track again.
        let newIndex: Int
        if queue.indices.contains(scheduledIndex), queue[scheduledIndex].track.id == trackID {
            newIndex = scheduledIndex
        } else if let found = queue.indices.first(where: { $0 > index && queue[$0].track.id == trackID })
                    ?? queue.indices.first(where: { queue[$0].track.id == trackID }) {
            newIndex = found
        } else {
            return scheduledIndex
        }
        // A blend hands over while the outgoing track is still audible: keep showing A→B.
        if let plan = transitionPlan, plan.toTrackID == trackID, plan.style != .gapless {
            isOutgoingTransitionTailAudible = true
        }
        index = newIndex
        let row = queue[newIndex]
        duration = row.track.durationSec ?? trackDuration
        if let seconds = mixDecks?.currentSeconds { currentTime = seconds }
        if let trackId = row.track.id {
            recordKeepPlayingHistory(trackId)
            Task { try? await LibraryStore.shared.recordPlay(trackId: trackId) }
        }
        updateNowPlaying()
        prefetchNext()
        maybeExtendKeepPlayingQueue()
        return newIndex
    }

    func mixDecksDidReachEnd(trackID: Int64) {
        guard currentTrack?.track.id == trackID else { return }
        if sleepAtEndOfTrack {
            sleepAtEndOfTrack = false
            pause()
            return
        }
        next()
    }

    /// Capabilities of the queue row's source from the one authority; never DB duration/rate or a stereo default.
    func liveMixCapabilities(at i: Int) -> AudioAssetCapabilities {
        let row = queue[i]
        let id = row.asset.map { "asset-\($0.id ?? $0.trackId)" } ?? "track-\(row.track.id ?? -1)"
        guard let asset = row.asset, let source = mixTrackSource(for: asset) else {
            return .unresolved(id, .unavailableSource)
        }
        switch source {
        case .remote:
            return audioCapabilities.capabilities(for: .remoteUncached(key: "remote-\(asset.trackId)"))
        case .file(let url, _, let securityScoped):
            let managed = asset.relPath.map { managedURL($0).path == url.path } ?? false
            if securityScoped || managed { return audioCapabilities.capabilities(for: .local(asset)) }
            return audioCapabilities.capabilities(for: .file(url, key: "cache-\(url.lastPathComponent)"))
        }
    }

    func releaseLiveMixReservation() {
        liveMixReservation?.release()
        liveMixReservation = nil
    }

    func mixDecksAdmission(index target: Int, outgoing: Int?) -> TransitionAdmissionDecision {
        // A new request replaces any earlier reservation first, so duplicates never stack.
        releaseLiveMixReservation()
        guard queue.indices.contains(target) else { return .gaplessFallback(reason: .unavailableSource) }
        audioCapabilities.onChange = { [weak self] in
            Task { @MainActor [weak self] in self?.mixDecks?.upcomingChanged() }
        }
        let incoming = liveMixCapabilities(at: target)
        let outgoingCaps = outgoing.flatMap { queue.indices.contains($0) ? liveMixCapabilities(at: $0) : nil }
        let decision = AudioAssetCapabilityService.decide(outgoing: outgoingCaps, incoming: incoming)
        guard decision == .allowLiveMix else { return decision }
        guard let bytes = AudioAssetCapabilityService.reservationBytes(outgoing: outgoingCaps, incoming: incoming) else {
            return .gaplessFallback(reason: .unavailableMetadata)
        }
        switch resourceCoordinator.reserve(.blendPreparation, bytes: bytes) {
        case .success(let reservation):
            liveMixReservation = reservation
            return .allowLiveMix
        case .failure(let denial):
            switch denial {
            case .absoluteCap: return .gaplessFallback(reason: .decodedMemoryBudget)
            case .invalidRequest: return .gaplessFallback(reason: .unavailableMetadata)
            default: return .gaplessFallback(reason: .memoryPressure)
            }
        }
    }

    func mixDecksDenied(index deniedIndex: Int, decision: TransitionAdmissionDecision) {
        releaseLiveMixReservation()
        // A late denial for a slot that no longer exists, or when the decks are gone, is obsolete.
        guard mixDecks != nil, let deniedOccurrence = mixDecksOccurrence(at: deniedIndex) else { return }
        liveMixFallback = TransitionFallbackStatus(decision: decision)
        if let from = mixDecksOccurrence(at: index), let to = mixDecksOccurrence(at: deniedIndex), deniedIndex != index {
            transitionExecution.record(TransitionEdgeKey(from: from, to: to), generation: transitionExecution.generation,
                                       .denied(.admissionDenied(liveMixFallback?.message ?? ""),
                                               readiness: .failed(liveMixFallback?.message ?? "")))
        }
        transitionPlan = nil
        transitionPrepState = .failed(liveMixFallback?.message ?? "")
        // Per-edge only: the "Everywhere" preference is untouched.
        let token = LiveMixFallbackToken(occurrence: deniedOccurrence, generation: transitionExecution.generation)
        guard deniedIndex == index else {
            liveMixFallbackToken = token
            // Prepare the denied upcoming track on the normal player now, so the handoff
            // does not wait for next() to build it.
            preloadNextItem(allowingMixDecks: true)
            return
        }
        // The current track itself was denied: play it on AVPlayer, never skip it,
        // keeping its position and play state.
        let resume = isPlaying
        let position = mixDecks?.currentSeconds ?? currentTime
        stopMixDecks()
        liveMixFallbackToken = token // after stop, which invalidates; consumed by the load below
        loadCurrent(autoplay: resume)
        liveMixFallbackToken = nil
        if position > 0.5 {
            player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
            currentTime = position
        }
    }

    func mixDecksCouldNotPlay(index failedIndex: Int, reason: String) {
        let title = queue.indices.contains(failedIndex) ? queue[failedIndex].track.title : "?"
        // Diagnostics carry an opaque load ID only: no title, path, URL or error text.
        mixDecksLog.error("mix decks: skipping load \(UUID().uuidString.prefix(8), privacy: .public): playback error")
        releaseLiveMixReservation()
        networkSkipMessage = String(localized: "Skipped \(title): \(reason)", bundle: .module)
        guard failedIndex == index else { return }
        next()
    }

    func mixDecksPosition(seconds: Double) {
        let previous = currentTime
        currentTime = seconds
        if abs(seconds - previous) >= 0.5 || seconds < previous {
            updateNowPlayingTime()
        }
        persistTick()
    }

    func mixDecksLoading(_ loading: Bool) {
        guard isStalled != loading else { return }
        isStalled = loading
        updateNowPlaying()
    }

    func mixDecksPublish(plan: TransitionPlan?, state: GridPrepState) {
        if let next = mixDecksUpcomingIndex(after: index), let key = mixDecksEdgeKey(from: index, to: next),
           transitionExecution.snapshot(for: key)?.isTerminal != true {
            transitionExecution.record(key, generation: transitionExecution.generation, .readiness(state))
        }
        if isOutgoingTransitionTailAudible {
            deferredTransitionPlan = (plan, state)
            return
        }
        transitionPlan = plan
        transitionPrepState = state
    }

    func mixDecksOutgoingDidFinish() {
        endOutgoingTransitionTail()
    }

    /// The outgoing track is inaudible (or the transition was cancelled): B→C may show now.
    func endOutgoingTransitionTail() {
        let deferred = deferredTransitionPlan
        deferredTransitionPlan = nil
        guard isOutgoingTransitionTailAudible || deferred != nil else { return }
        isOutgoingTransitionTailAudible = false
        if let deferred {
            transitionPlan = deferred.plan
            transitionPrepState = deferred.state
        } else {
            transitionPlan = nil
        }
    }

    // MARK: - Sources

    /// Where the mix decks read an asset: the same choices as `buildItem`
    /// (Opus CAF, bundled, complete cache, stream, bookmark, managed file).
    func mixTrackSource(for asset: Asset) -> MixTrackSource? {
        if let opusString = asset.opusRemoteURL, let opusURL = URL(string: opusString) {
            let caf = AudioCache.cafURL(forRemoteOpus: opusURL)
            if FileManager.default.fileExists(atPath: caf.path) {
                return .file(caf, container: .caf, securityScoped: false)
            }
        }
        if asset.kind == .builtIn, let channelId = asset.relPath,
           let url = BuiltInContentProvider.bundledAudioURL(forChannelId: channelId) {
            return .file(url, container: .auto, securityScoped: false)
        }
        if asset.kind == .remote, let urlString = remoteURLString(for: asset), let remote = URL(string: urlString) {
            let container = remote.pathExtension.isEmpty
                ? MixTrackLoader.container(forMIME: remoteAudioMIMEType(for: remote)) : .auto
            if AudioCache.completeCacheExists(for: remote) {
                let cached = AudioCache.fileURL(for: AudioCache.key(for: remote))
                if FileManager.default.fileExists(atPath: cached.path) {
                    return .file(cached, container: container == .auto
                                 ? MixTrackLoader.container(forExtension: remote.pathExtension) : container,
                                 securityScoped: false)
                }
            }
            let cacheKey = asset.transientRemoteSupportsByteRanges ? AudioCache.key(for: remote) : nil
            return .remote(remote, headers: asset.transientRemoteHeaders, container: container, cacheKey: cacheKey)
        }
        if let bookmark = asset.bookmark, let (url, _) = BookmarkVault.resolve(bookmark) {
            return .file(url, container: .auto, securityScoped: true)
        }
        if let rel = asset.relPath {
            return .file(managedURL(rel), container: .auto, securityScoped: false)
        }
        return nil
    }
}
#endif

extension AudioPlayer {
    /// The displayed edge for the playing track: A→B until A is inaudible, then B→C.
    public var transitionPresentation: TransitionPresentation {
        if isAmbient || queue.isEmpty { return .none }
        let hasNext = index + 1 < queue.count || repeatMode == .all
        // A plan for tracks that are no longer the playing/next pair (queue replaced) is stale.
        var plan = transitionPlan
        if !isOutgoingTransitionTailAudible, let p = plan, queue.indices.contains(index),
           let current = queue[index].track.id, p.fromTrackID != current {
            plan = nil
        }
        return TransitionPresentation.make(plan: plan, preparation: transitionPrepState,
                                           hasNext: hasNext || isOutgoingTransitionTailAudible,
                                           position: currentTime,
                                           outgoingTail: isOutgoingTransitionTailAudible)
            .applying(displayedTransitionSnapshot)
    }

    /// The renderer's snapshot for the edge Now Playing shows: the audible one, else the next edge.
    public var displayedTransitionSnapshot: TransitionExecutionSnapshot? {
        if let active = transitionExecution.active,
           active.phase == .overlapping || isOutgoingTransitionTailAudible { return active }
        return transitionExecutionSnapshot(afterQueueIndex: index)
    }
}
