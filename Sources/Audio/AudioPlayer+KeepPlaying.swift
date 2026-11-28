#if !os(watchOS)
import Foundation

/// Keep Playing as an endless BPM/key/energy mix. The provider returns the
/// next track ids in play order, plus whether it had to fall back from the
/// strict ±8%/compatible-key rule to the nearest analysed match.
public protocol KeepPlayingMixProviding: Sendable {
    func mixContinuation(after trackID: Int64, excluding: Set<Int64>, limit: Int) async -> KeepPlayingMixResult
}

public struct KeepPlayingMixResult: Equatable, Sendable {
    public let trackIDs: [Int64]
    /// True when no strict Build-a-Mix pair existed and the nearest analysed
    /// tracks by BPM/key/energy were used instead.
    public let isRelaxed: Bool

    public init(trackIDs: [Int64] = [], isRelaxed: Bool = false) {
        self.trackIDs = trackIDs
        self.isRelaxed = isRelaxed
    }

    public static let empty = KeepPlayingMixResult()
}

/// Why a Keep Playing extension fell back to a shuffle-continue instead of a
/// musical pick. Kept distinct from a plain `Bool` so the UI can give an
/// honest, specific reason instead of a generic "something went wrong"
/// (CLAUDE.md "no silent/magic background work").
public enum KeepPlayingFallbackReason: Equatable, Sendable {
    /// No analysed BPM/key/energy candidate was available at all, so Keep
    /// Playing fell back to a visible shuffle rather than dead air.
    case noCompatibleTracks
}

/// The terminal end-of-queue state of Keep Playing, tied to a queue
/// generation so completions from a replaced queue are ignored.
enum KeepPlayingBoundaryState: Equatable {
    case idle
    /// `next()` hit the last item while an extension was in flight.
    case waiting(queueGeneration: Int, terminalIndex: Int)
    /// The extension finished with no playable rows; nothing retries until
    /// the queue changes or the user loads another item.
    case exhausted(queueGeneration: Int, terminalIndex: Int)

    var isExhausted: Bool {
        if case .exhausted = self {
            return true
        }
        return false
    }
}

extension AudioPlayer {
    // MARK: - Keep Playing

    /// Drops any waiting/exhausted boundary and invalidates completions that
    /// were computed for it.
    func resetKeepPlayingBoundary() {
        keepPlayingBoundaryGeneration &+= 1
        keepPlayingBoundaryState = .idle
    }

    /// Records a track as played in the current continuous-play session, so
    /// Keep Playing never re-suggests it. Cheap no-op re-append guard: this is
    /// called once per `loadCurrent`, which only runs when the current index
    /// actually changes to a new/track reload, so consecutive duplicates here
    /// would only happen for genuine repeats (repeat-one), which is fine —
    /// the exclusion set below is a `Set`, not the ordered array itself.
    func recordKeepPlayingHistory(_ trackId: Int64) {
        keepPlayingHistory.append(trackId)
    }

    /// Checks whether the manually-built queue is about to run out and, if
    /// Keep Playing is on, kicks off an async extension. Called from
    /// `loadCurrent` every time the current track changes — cheap to call
    /// repeatedly since `keepPlayingLastExtensionAttemptIndex` guards against
    /// firing twice for the same position.
    func maybeExtendKeepPlayingQueue() {
        guard KeepPlayingPicker.shouldAttemptExtension(
            enabled: keepPlayingEnabled, isAmbient: isAmbient, repeatMode: repeatMode,
            queueCount: queue.count, index: index,
            lastAttemptedIndex: keepPlayingLastExtensionAttemptIndex,
            extensionInFlight: keepPlayingExtensionInFlight,
            unplayedAutoCount: unplayedKeepPlayingCount)
        else { return }

        keepPlayingLastExtensionAttemptIndex = index
        keepPlayingExtensionInFlight = true
        keepPlayingExtensionTask?.cancel()
        keepPlayingExtensionTask = Task { [weak self] in
            await self?.performKeepPlayingExtension()
        }
    }

    /// Future queue entries whose origin is `.keepPlaying`.
    var unplayedKeepPlayingCount: Int {
        queueEntries.enumerated().filter { $0.offset > index && $0.element.origin.isKeepPlaying }.count
    }

    /// Maximum number of tracks an extension may append right now.
    var keepPlayingHorizonBudget: Int {
        KeepPlayingPicker.horizonBudget(unplayedAutoCount: unplayedKeepPlayingCount)
    }

    private func currentKeepPlayingExclusions() async -> Set<Int64> {
        // Session exclusions plus the durable "never recommend" / removed-from-library identities
        // resolved to their current local track ids (covers re-added tracks).
        let durable = await keepPlayingLibrary.excludedTrackIDs()
        return Set(keepPlayingHistory).union(queue.compactMap { $0.track.id }).union(durable)
    }

    private func performKeepPlayingExtension() async {
        defer { keepPlayingExtensionInFlight = false }
        // A fresh `play(tracks:)` or a test's `resetRestoreForTesting()`
        // cancels the previous extension task outright rather than letting
        // it resolve against state it was never computed for — check right
        // away and after every suspension point below, since `AudioPlayer`
        // is a process-wide singleton and this task can otherwise keep
        // running well past the session (or test) that started it.
        guard !Task.isCancelled else { return }
        guard keepPlayingHorizonBudget > 0 else { return }
        let excluded = await currentKeepPlayingExclusions()

        // Keep Playing is an endless mix: continue from the last queued
        // track under Build a Mix's BPM/key/energy rules first.
        if let mixProvider = keepPlayingMixProvider, let anchor = queue.last?.track.id {
            let result = await mixProvider.mixContinuation(
                after: anchor, excluding: excluded, limit: keepPlayingHorizonBudget)
            guard !Task.isCancelled else { return }
            if !result.trackIDs.isEmpty {
                await appendKeepPlayingMixTracks(
                    result.trackIDs,
                    recommendation: result.isRelaxed ? .relaxedMixMatched : .mixMatched)
                return
            }
        }

        if case .continuation(let source) = queueSource {
            let rows = await source.nextTracks(excluding: excluded, limit: keepPlayingHorizonBudget)
            guard !Task.isCancelled else { return }
            if !rows.isEmpty {
                finishKeepPlayingExtension(with: rows, isFallback: false, reason: nil)
            } else {
                await extendWithFallback(excluding: excluded)
            }
            return
        }

        await extendWithFallback(excluding: excluded)
    }

    /// Hydrates mix-picked core track ids into `TrackRow`s and appends
    /// them. Falls back if none of the ids could be hydrated (e.g. a track
    /// was deleted between the lookup and now) rather than silently
    /// appending nothing.
    private func appendKeepPlayingMixTracks(
        _ ids: [Int64], recommendation: KeepPlayingRecommendationReason
    ) async {
        var rows: [TrackRow] = []
        for id in ids {
            if let row = await keepPlayingLibrary.trackRow(id) {
                rows.append(row)
            }
        }
        // Snapshot the analysed BPM/key now so the explanation never changes
        // on a later re-index.
        let mix = await keepPlayingLibrary.djLoadTrackInfo(ids)
        guard !Task.isCancelled else { return }
        guard !rows.isEmpty else {
            await extendWithFallback(excluding: await currentKeepPlayingExclusions())
            return
        }
        finishKeepPlayingExtension(
            with: rows, isFallback: false, reason: nil,
            recommendation: recommendation, mix: mix)
    }

    /// The honest fallback: shuffle-continue from the same source/library
    /// scope already playing, never a silent no-op (CLAUDE.md "no silent/
    /// magic background work") — `keepPlayingLastExtensionWasFallback`/
    /// `keepPlayingFallbackReason` always record that this happened and why.
    private func extendWithFallback(excluding excluded: Set<Int64>) async {
        let pool = await keepPlayingFallbackPool()
        guard !Task.isCancelled else { return }
        func usable(_ rows: [TrackRow]) -> [TrackRow] {
            rows.filter { row in
                guard let id = row.track.id else { return false }
                return !excluded.contains(id)
            }
        }
        var candidates = usable(pool)
        if candidates.isEmpty {
            // Real report: one Google Drive track with Keep Playing on was a
            // dead end — that source's persisted rows were just the one
            // playing track, so the source-scoped pool had nothing left. No
            // dead air: broaden to the whole library (the exclusion set still
            // prevents every played/queued track), exactly as the playlist
            // fallback already does.
            let all = await keepPlayingLibrary.allTrackRows()
            guard !Task.isCancelled else { return }
            candidates = usable(all)
        }
        let picked = keepPlayingFallbackOrder(candidates)
        finishKeepPlayingExtension(
            with: picked, isFallback: true, reason: .noCompatibleTracks,
            recommendation: .noMatchShuffle)
    }

    /// The candidate pool for the fallback shuffle-continue: whatever
    /// source/playlist/library scope this queue was actually started from —
    /// never a silently different scope than the one the user was playing
    /// from.
    private func keepPlayingFallbackPool() async -> [TrackRow] {
        switch queueSource {
        case .source(let source):
            guard let sourceId = source.id else { return await keepPlayingLibrary.allTrackRows() }
            return await keepPlayingLibrary.tracksForSource(sourceId)
        case .playlist(let playlist):
            // A playlist is the queue's starting scope, not a boundary for
            // Keep Playing. Once every playlist item is excluded, using the
            // same playlist as the fallback pool guarantees dead air. Broaden
            // to the library; the exclusion set still prevents repeats of
            // every played and queued track.
            _ = playlist
            return await keepPlayingLibrary.allTrackRows()
        case .library, .none, .continuation:
            return await keepPlayingLibrary.allTrackRows()
        case .ambient:
            return []
        }
    }

    /// Appends the chosen rows (real mix picks or fallback picks) to the live
    /// queue and records the outcome for the UI. Recording the outcome happens
    /// even when `rows` is empty — a fallback that found nothing to add is
    /// still a real, visible result, not silence.
    func finishKeepPlayingExtension(
        with rows: [TrackRow], isFallback: Bool, reason: KeepPlayingFallbackReason?,
        recommendation: KeepPlayingRecommendationReason = .mixMatched,
        mix: [Int64: DJLoadTrackInfo] = [:]
    ) {
        // Re-apply the horizon budget and diversity rules at append time, so a stale or
        // overlapping task can never overfill the horizon. Provider order is preserved.
        let rows = diverseKeepPlayingRows(rows)
        keepPlayingLastExtensionWasFallback = isFallback
        keepPlayingFallbackReason = isFallback ? reason : nil
        // `next()` set this when it hit the end of the queue while this
        // extension was still running — clear it either way, since the wait is
        // over regardless of whether it produced anything playable.
        var resumeIndex: Int?
        var exhaustedGeneration: Int?
        if case .waiting(let generation, let terminalIndex) = keepPlayingBoundaryState {
            if generation == keepPlayingBoundaryGeneration, keepPlayingEnabled,
                terminalIndex == index, terminalIndex == queue.count - 1
            {
                resumeIndex = terminalIndex
                exhaustedGeneration = generation
            } else {
                // Stale or disabled: drop the wait without resuming.
                keepPlayingBoundaryState = .idle
            }
        }
        guard !rows.isEmpty else {
            if let terminal = resumeIndex, let generation = exhaustedGeneration {
                keepPlayingBoundaryState = .exhausted(queueGeneration: generation, terminalIndex: terminal)
            }
            // An empty result is not a terminal queue state. Allow the end
            // callback to make one fresh fallback attempt instead of being
            // suppressed forever by the per-index gate.
            keepPlayingLastExtensionAttemptIndex = nil
            return
        }

        queueEntries = QueueEditor.State<PlaybackQueueEntry>.appendingKeepPlaying(
            rows, reason: recommendation, mix: mix,
            in: QueueEditor.State(queue: queueEntries, currentIndex: index)).queue
        if shuffle { unshuffledQueue = queueEntries }
        for row in rows {
            if let id = row.track.id { keepPlayingAutoAddedTrackIDs.insert(id) }
        }
        prefetchNext()
        preloadNextItem()
        persist(reason: .transportEvent)
        // The newly-appended rows are real tracks the player was waiting on
        // — actually start them instead of leaving them queued-but-silent.
        // Still gated on keepPlayingEnabled: if the user turned it off while
        // this extension was in flight, honor that rather than resuming
        // playback they just asked to stop auto-extending.
        if resumeIndex != nil {
            keepPlayingBoundaryState = .idle
            next()
        }
    }

    private func diverseKeepPlayingRows(_ rows: [TrackRow]) -> [TrackRow] {
        func candidate(_ row: TrackRow) -> KeepPlayingPicker.Candidate? {
            guard let id = row.track.id else { return nil }
            return .init(id: id, artist: row.artist?.name ?? row.album?.artist, album: row.album?.title)
        }
        let lookback =
            queueEntries.indices.contains(index)
            ? queueEntries[max(0, index - 2)...index].compactMap { candidate($0.row) } : []
        let excluded = Set(keepPlayingHistory).union(queueEntries.compactMap { $0.row.track.id })
        let byID = Dictionary(
            rows.compactMap { r in r.track.id.map { ($0, r) } },
            uniquingKeysWith: { first, _ in first })
        let plan = KeepPlayingPicker.plan(
            candidates: rows.compactMap(candidate), excluded: excluded, lookback: lookback,
            budget: keepPlayingHorizonBudget)
        keepPlayingLastPlanRelaxedAlbum = plan.relaxedAlbum
        keepPlayingLastPlanRelaxedArtist = plan.relaxedArtist
        return plan.picks.compactMap { byID[$0.id] }
    }

    /// Removes the not-yet-played auto-added tail from the queue — called
    /// when the user turns Keep Playing off, and exposed directly as the
    /// "Clear auto-added tracks" affordance. Already-played auto-added
    /// entries (before `index`) are left in the queue/history untouched.
    public func removeUnplayedKeepPlayingTracks() {
        let offsets = queueEntries.enumerated().compactMap { offset, entry -> Int? in
            offset > index && entry.origin.isKeepPlaying ? offset : nil
        }
        guard !offsets.isEmpty else { return }
        removeFromQueue(atOffsets: IndexSet(offsets))
        // Freed horizon budget permits one fresh refill at this position.
        keepPlayingLastExtensionAttemptIndex = nil
        let remaining = Set(queueEntries.compactMap { $0.origin.isKeepPlaying ? $0.row.track.id : nil })
        keepPlayingAutoAddedTrackIDs.formIntersection(remaining)
    }

    /// Test-only seam: runs the extension synchronously (awaiting it directly
    /// instead of through the fire-and-forget `Task` in
    /// `maybeExtendKeepPlayingQueue`) so tests can assert on the result
    /// without racing a background task.
    func extendKeepPlayingQueueForTesting() async {
        keepPlayingExtensionInFlight = true
        await performKeepPlayingExtension()
    }
}
#endif
