#if !os(watchOS)
import Foundation
import AVFoundation
import OSLog

private let starterLog = Logger(subsystem: "guru.parso.tonearm", category: "StarterStream")

/// The Starter Blend a queue was started from: what the streaming renderer needs and nothing
/// that could be re-planned at play time.
struct StarterSession {
    let blendID: String
    let pack: StarterBlendPack
    private var trackIDsStorage: [String]
    private var plansStorage: [BlendEdgePlan]
    private var rowIDsStorage: [Int64?]
    var trackIDs: [String] { trackIDsStorage }
    var plans: [BlendEdgePlan] { plansStorage }
    var rowIDs: [Int64?] { rowIDsStorage }
    /// Streaming stopped (or was never possible): the rest plays in order, with no blend.
    var sequential = false

    init(_ request: StarterPlayRequest) {
        blendID = request.blendID
        pack = request.pack
        trackIDsStorage = request.trackIDs
        plansStorage = request.edgePlans
        rowIDsStorage = request.rows.map(\.track.id)
    }

    mutating func append(trackIDs ids: [String], plans more: [BlendEdgePlan], rowIDs rows: [Int64?]) {
        trackIDsStorage += ids; plansStorage += more; rowIDsStorage += rows
    }

    /// Every edge has a supplied plan that resolves against the tracks' facts.
    var isExecutable: Bool {
        guard plans.count == trackIDs.count - 1 else { return false }
        for (i, plan) in plans.enumerated() {
            guard plan.outgoingTrackID == trackIDs[i], plan.incomingTrackID == trackIDs[i + 1],
                  plan.schedule() != nil else { return false }
        }
        return true
    }
}

extension AudioPlayer {
    /// Plays a Starter Blend: the rows form the queue (Now Playing, Queue and Keep Playing see an
    /// ordinary queue) while the audio streams from the release on the bounded Starter decks,
    /// executing `request.edgePlans`. A request that is not blended plays the rows in order.
    public func playStarterBlend(_ request: StarterPlayRequest) {
        endStarterSession()
        var session = StarterSession(request)
        if !request.isBlended { session.sequential = true }
        pendingStarterSession = session
        play(tracks: request.rows, startAt: 0, source: .none)
    }

    /// Called at the top of `play(tracks:)`: a queue that is not the pending starter one ends the session.
    func adoptPendingStarterSession() {
        let pending = pendingStarterSession
        pendingStarterSession = nil
        if pending == nil { endStarterSession() }
        starterSession = pending
    }

    /// The Starter Blend this queue was started from, while it is still the queue.
    public var activeStarterBlendID: String? { starterSession?.blendID }

    /// Shuffle (or another reorder) made the queue differ from the blend: the planned edges no longer
    /// join adjacent tracks, so the blend stops and the queue plays in its new order, saying so.
    func starterQueueOrderChanged() {
        guard let session = starterSession, !session.sequential, starterStream != nil else { return }
        let matches = queue.count >= session.trackIDs.count
            && zip(queue, session.rowIDs).allSatisfy { $0.track.id == $1 }
        guard !matches else { return }
        fallBackToSequential(reason: "The queue order changed, so this blend plays without its transitions.",
                             retryable: false, resumeSeconds: starterStream?.positionSeconds ?? currentTime,
                             playingIndex: index)
    }

    /// Play after a Starter Blend ran out (its stream is gone, the session is not a fallback): stream the
    /// current track again rather than asking an empty AVPlayer to play.
    func restartEndedStarterSession() -> Bool {
        guard let session = starterSession, !session.sequential, starterStream == nil, !isPlaying,
              queue.indices.contains(index) else { return false }
        loadCurrent(autoplay: true)
        return true
    }

    func stopStarterStream() {
        starterStream?.stop()
        starterStream = nil
    }

    func endStarterSession() {
        stopStarterStream()
        if let session = starterSession { starterStatus = .stopped(blendID: session.blendID) }
        starterSession = nil
        pendingStarterSession = nil
    }

    /// Streams the current track (and the planned edges after it) on the Starter decks. False when
    /// this queue is not a live starter session; the caller then plays it the ordinary way.
    func loadCurrentOnStarterStream(row: TrackRow, autoplay: Bool) -> Bool {
        guard let session = starterSession, !isAmbient else {
            if starterStream != nil { stopStarterStream() }
            return false
        }
        if session.sequential {
            if starterStream != nil { stopStarterStream() }
            return false
        }
        let matches = queue.count >= session.trackIDs.count
            && zip(queue, session.rowIDs).allSatisfy { $0.track.id == $1 }
        guard index < session.trackIDs.count, matches else {
            endStarterSession()
            return false
        }
        guard session.isExecutable else {
            fallBackToSequential(reason: "This blend's transition plan is incomplete.", retryable: false, resumeSeconds: 0,
                                 playingIndex: index)
            return true
        }
        stopMixDecks()
        cancelCrossfade(resetVolume: true)
        shutdownLoaders()
        dropPreloadedNext()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isOutgoingTransitionTailAudible = false
        deferredTransitionPlan = nil
        transitionPlan = nil
        if starterStream == nil { starterStream = makeStarterStream(session) }
        currentTime = 0
        duration = row.track.durationSec ?? 0
        isPlaying = autoplay
        starterStatus = .buffering(blendID: session.blendID)
        recordPlannedEdges(session, from: index)
        starterStream?.volume = outputLevel
        starterStream?.start(at: index)
        if !autoplay { starterStream?.pause() }
        updateNowPlaying()
        if autoplay, let trackId = row.track.id {
            Task { try? await LibraryStore.shared.recordPlay(trackId: trackId) }
        }
        maybeExtendKeepPlayingQueue()
        return true
    }

    private func makeStarterStream(_ session: StarterSession) -> StarterStreamPlayer {
        let opener = CatalogSourceOpener.live()
        let override = starterSourceFactoryOverride
        let output: StarterLiveOutput? = override == nil
            ? StarterLiveOutput(cell: { [weak self] in self?.starterStream?.cell },
                                sampleRate: { [weak self] in self?.starterStream?.sampleRate ?? 44_100 })
            : nil
        return StarterStreamPlayer(
            config: .init(trackIDs: session.trackIDs, plans: session.plans),
            host: self, output: output,
            makeSource: override ?? { trackID, cancellation in
                // Resolved from the catalog row's durable locator: Starter assets read only the pinned
                // release, Jamendo rows resolve/refresh through the Jamendo client. Byte ranges only.
                try opener.openBlocking(trackID: trackID, cancellation: cancellation)
            })
    }

    /// Keep Playing for a Starter Blend: appends blend-eligible catalog tracks that follow the last
    /// track under the catalog's own rules, each edge planned from stored facts and persisted as
    /// `edgePlanned`. Nothing is selected from outside the catalog, and no model runs.
    func extendStarterSessionFromCatalog(_ session: StarterSession) async {
        let pack = session.pack
        let catalog = (try? await LibraryStore.shared.blendCatalogTracks(atLeast: .blendEligible, packTag: pack.releaseTag)) ?? []
        guard !Task.isCancelled else { return }
        // Only rows with every required fact (tempo grid, genre, valid key) and a resolvable mirrored
        // locator are ever considered. Camelot rule: same code, ±1 same mode, or relative major/minor.
        let selectable = catalog.filter { $0.isKeepPlayingCandidate(in: pack) }
        var facts: [String: StarterTrackFacts] = [:]
        var traits: [String: BlendTraits] = [:]
        for row in selectable { facts[row.trackID] = row.facts; traits[row.trackID] = row.traits }
        var candidates = selectable.map(\.trackID).filter { !session.trackIDs.contains($0) }
        var chain: [String] = [], plans: [BlendEdgePlan] = []
        var tail = session.trackIDs.last
        while chain.count < min(keepPlayingBatchSize, 5), let tailID = tail, let outgoing = facts[tailID],
              let outgoingTraits = traits[tailID] {
            let options = candidates.compactMap { id -> (String, BlendEdgePlan)? in
                guard let incoming = facts[id], let incomingTraits = traits[id],
                      outgoingTraits.isCompatible(with: incomingTraits),
                      let plan = CatalogEdgePlanner.plan(blendID: session.blendID,
                                                         edge: session.trackIDs.count + chain.count,
                                                         outgoing: outgoing, incoming: incoming) else { return nil }
                return (id, plan)
            }
            // Prefer an exact subgenre match over a broad-genre-only one, then the closest tempo.
            guard let best = options.min(by: { lhs, rhs in
                let l = outgoingTraits.sharesSubgenre(with: traits[lhs.0]!), r = outgoingTraits.sharesSubgenre(with: traits[rhs.0]!)
                if l != r { return l }
                return abs(lhs.1.tempo - 1) < abs(rhs.1.tempo - 1)
            }) else { break }
            chain.append(best.0); plans.append(best.1)
            candidates.removeAll { $0 == best.0 }
            tail = best.0
        }
        guard !chain.isEmpty else {
            appendPlayableContinuationFallback(for: session)
            return
        }
        var previous = session.trackIDs.last ?? ""
        for (id, plan) in zip(chain, plans) {
            // An edge that cannot be persisted is not a real plan: stop here and extend nothing.
            do {
                try await LibraryStore.shared.recordBlendEdgePlan(
                    plan, from: BlendCatalogTrack.key(pack: pack, trackID: previous),
                    to: BlendCatalogTrack.key(pack: pack, trackID: id), packTag: pack.releaseTag)
            } catch {
                finishKeepPlayingExtension(with: [], isFallback: true, reason: .unavailable)
                return
            }
            previous = id
        }
        guard let rows = try? StarterBlendPlayback.rows(blendID: session.blendID, title: "Keep Playing", trackIDs: chain, pack: pack),
              rows.count == chain.count else {
            finishKeepPlayingExtension(with: [], isFallback: true, reason: .unavailable)
            return
        }
        guard var current = starterSession, current.blendID == session.blendID, !current.sequential else { return }
        current.append(trackIDs: chain, plans: plans, rowIDs: rows.map(\.track.id))
        starterSession = current
        starterStream?.extend(trackIDs: chain, plans: plans)
        finishKeepPlayingExtension(with: rows, isFallback: false, reason: nil)
    }

    /// The preferred blended continuation has no candidate: append a complete verified pack card
    /// in order so the queue does not end in silence. The bridge is ordinary sequential playback
    /// (no `BlendEdgePlan`, no blend claimed) and is reported as the `.unavailable` fallback.
    /// A card with an unplayed track is preferred; otherwise one card is repeated, deterministically.
    func appendPlayableContinuationFallback(for session: StarterSession) {
        let pack = session.pack
        let cards = StarterBlendCatalog.blends.filter { $0.pack.releaseTag == pack.releaseTag }
        let used = Set(session.trackIDs)
        func complete(_ blend: StarterBlend) -> [TrackRow]? {
            let rows = (try? StarterBlendPlayback.catalogRows(for: blend)) ?? []
            return !rows.isEmpty && rows.count == blend.trackIDs.count ? rows : nil
        }
        let fresh = cards.first { card in
            card.trackIDs.contains { !used.contains($0) } && complete(card) != nil
        }
        let repeated = cards.first { $0.id == session.blendID && complete($0) != nil }
            ?? cards.first { complete($0) != nil }
        guard let card = fresh ?? repeated, let rows = complete(card),
              var current = starterSession, current.blendID == session.blendID, !current.sequential else {
            finishKeepPlayingExtension(with: [], isFallback: true, reason: .unavailable)
            return
        }
        current.sequential = true
        starterSession = current
        finishKeepPlayingExtension(with: rows, isFallback: true, reason: .unavailable)
    }

    /// Every edge of the loaded blend has a concrete plan, so every edge is published as planned
    /// and ready from the start; the renderer's reports then move them through overlap and handoff.
    private func recordPlannedEdges(_ session: StarterSession, from start: Int) {
        for (offset, plan) in session.plans.enumerated() where offset >= start {
            guard let key = starterEdgeKey(from: offset, to: offset + 1) else { continue }
            let style = Self.displayStyle(plan.style)
            transitionExecution.record(key, generation: transitionExecution.generation,
                                       .scheduled(requested: style, planned: style, executed: style, readiness: .ready,
                                                  reason: nil, overlapStart: nil, overlapEnd: nil, handoff: nil,
                                                  sampleRate: 44_100))
        }
    }

    static func displayStyle(_ style: BlendEdgePlan.Style) -> TransitionDisplayStyle {
        switch style {
        case .bassSwap: return .bassSwap
        case .doubleDrop: return .doubleDrop
        case .phraseCut: return .phraseBlend
        }
    }

    private func starterEdgeKey(from: Int, to: Int) -> TransitionEdgeKey? {
        guard queueOccurrences.indices.contains(from), queueOccurrences.indices.contains(to) else { return nil }
        return TransitionEdgeKey(from: queueOccurrences[from], to: queueOccurrences[to])
    }

    /// Streaming cannot continue: say exactly why, then play from where the listener is in order
    /// with the ordinary player. No blend is claimed for what follows.
    func fallBackToSequential(reason: String, retryable: Bool, resumeSeconds: Double, playingIndex: Int) {
        guard var session = starterSession else { return }
        session.sequential = true
        starterSession = session
        let resume = isPlaying
        stopStarterStream()
        transitionExecution.cancelAll(reason: .stopped)
        starterStatus = .sequential(blendID: session.blendID, reason: reason, retryable: retryable)
        index = min(max(0, playingIndex), max(0, queue.count - 1))
        loadCurrent(autoplay: resume)
        if resumeSeconds > 1 { seek(to: resumeSeconds) }
    }
}

extension AudioPlayer: StarterStreamHost {
    func starterStreamBuffering(_ buffering: Bool) {
        guard let session = starterSession else { return }
        starterStatus = buffering ? .buffering(blendID: session.blendID) : .blending(blendID: session.blendID)
    }

    func starterStreamDidAdvance(to newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        index = newIndex
        currentTime = 0
        duration = queue[newIndex].track.durationSec ?? 0
        updateNowPlaying()
        persist(reason: .transportEvent)
        if let trackId = queue[newIndex].track.id {
            recordKeepPlayingHistory(trackId)
            Task { try? await LibraryStore.shared.recordPlay(trackId: trackId) }
        }
        maybeExtendKeepPlayingQueue()
    }

    func starterStreamPosition(seconds: Double) {
        guard isPlaying, abs(seconds - currentTime) >= 0.25 else { return }
        currentTime = seconds
        updateNowPlayingTime()
    }

    func starterStreamDidFinish() {
        stopStarterStream()
        if sleepAtEndOfTrack {
            sleepAtEndOfTrack = false
            pause()
            return
        }
        if repeatMode == .one { loadCurrent(autoplay: true); return }
        next()
    }

    func starterStreamAllowsBlend(from index: Int) -> Bool { repeatMode != .one && !sleepAtEndOfTrack }

    func starterStreamDidFail(_ failure: StarterStreamFailure) {
        starterLog.error("falling back to sequential: \(failure.message, privacy: .public) retryable=\(failure.retryable, privacy: .public)")
        // `failure.trackIndex` may be the incoming track; what is audible is `playingIndex`.
        let resume = failure.trackIndex == failure.playingIndex ? 0 : failure.resumeSeconds
        fallBackToSequential(reason: failure.message, retryable: failure.retryable, resumeSeconds: resume,
                             playingIndex: failure.playingIndex)
    }

    func starterStreamEdge(_ event: StarterEdgeEvent) {
        switch event {
        case let .scheduled(edge, plan, executed):
            guard let key = starterEdgeKey(from: edge - 1, to: edge) else { return }
            let planned = Self.displayStyle(plan.style)
            if let executed {
                let style = Self.displayStyle(executed)
                transitionExecution.record(key, generation: transitionExecution.generation,
                                           .scheduled(requested: planned, planned: planned, executed: style,
                                                      readiness: .ready, reason: nil, overlapStart: nil,
                                                      overlapEnd: nil, handoff: nil, sampleRate: 44_100))
            } else {
                // The listener moved past the planned point: this edge follows on, and says so.
                transitionExecution.record(key, generation: transitionExecution.generation,
                                           .scheduled(requested: planned, planned: planned, executed: .gapless,
                                                      readiness: .ready, reason: .lateForPlannedBlend,
                                                      overlapStart: nil, overlapEnd: nil, handoff: nil,
                                                      sampleRate: 44_100))
            }
        case let .overlapBegan(edge, frame):
            guard let key = starterEdgeKey(from: edge - 1, to: edge) else { return }
            transitionExecution.record(key, generation: transitionExecution.generation, .overlapBegan(atFrame: frame))
        case let .handedOff(edge, frame):
            guard let key = starterEdgeKey(from: edge - 1, to: edge) else { return }
            transitionExecution.record(key, generation: transitionExecution.generation, .handedOff(atFrame: frame))
            transitionExecution.outgoingFinished(key, generation: transitionExecution.generation, atFrame: frame)
        }
    }
}
#endif
