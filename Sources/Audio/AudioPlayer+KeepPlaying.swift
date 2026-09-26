#if !os(watchOS)
import Foundation

/// One "Keep Playing" continuation lookup's outcome. Mirrors the vocabulary
/// `Sources/Discovery/IndexStatusModel.swift` already uses for the sound-index
/// status surface (`waitingForModel` vs. a real "nothing here" case) so the two
/// features never invent two different ways of saying "the model isn't ready
/// yet" (CLAUDE.md "no silent/magic background work").
public enum KeepPlayingLookup: Equatable, Sendable {
    /// Real CLAP nearest-neighbor candidates, already excluding the caller's
    /// `excluding` set, ordered best match first.
    case ready([Int64])
    /// Sound-similar candidates returned after the requested Camelot/BPM
    /// gate had no results. This is still surfaced as a visible fallback.
    case readyFromBroaderSimilarity([Int64])
    /// The CLAP model/index isn't available yet (downloading, or indexing
    /// hasn't produced an embedding for the reference track). Distinct from
    /// `.unavailable` so the fallback can say *why* it's a fallback.
    case waitingForModel
    /// The model is available but no usable similarity candidates exist for
    /// this reference (empty library/scope, a real search failure, etc).
    case unavailable
}

/// The CLAP-similarity seam Keep Playing calls to pick its continuation
/// tracks. `TonearmCore` (this file's target) cannot import
/// `TonearmDiscovery` — that package already depends on `TonearmCore`, so a
/// reverse import would cycle — so the app wires in the real implementation
/// (backed by `SearchService`/`VectorIndex`) after launch via
/// `AudioPlayer.keepPlayingProvider`. Everything here stays host-testable
/// with the seam left `nil`, which always takes the honest fallback path.
public protocol KeepPlayingSimilarityProviding: Sendable {
    /// - Parameters:
    ///   - recentlyPlayed: core track ids played this continuous-play
    ///     session, most-recently-played first. The implementation runs the
    ///     similarity search against `recentlyPlayed.first`.
    ///   - excluding: ids that must never appear in the result (already-queued
    ///     tracks and this session's play history) — the provider is
    ///     responsible for filtering these out before returning, since only it
    ///     knows how many extra candidates to fetch to still hit `limit`.
    ///   - limit: how many track ids to return at most.
    func continuationTrackIDs(
        after recentlyPlayed: [Int64], excluding: Set<Int64>, matchingTracksOnly: Bool, limit: Int
    ) async -> KeepPlayingLookup
}

/// Why a Keep Playing extension fell back to a shuffle-continue instead of a
/// real CLAP similarity pick. Kept distinct from a plain `Bool` so the UI can
/// give an honest, specific reason instead of a generic "something went
/// wrong" (CLAUDE.md "no silent/magic background work").
public enum KeepPlayingFallbackReason: Equatable, Sendable {
    /// The sound-search model/index isn't ready yet (still downloading, or
    /// the reference track has no embedding). Not a dead end — it retries
    /// itself as indexing/model download progresses.
    case waitingForModel
    /// The model is available but no similarity candidates exist right now
    /// (e.g. everything eligible is already in the queue/history, or a real
    /// search error occurred).
    case unavailable
    /// No Camelot/BPM-compatible candidate was available, so Keep Playing
    /// broadened to ordinary sound similarity.
    case matchingUnavailable
}

extension AudioPlayer {
    // MARK: - Keep Playing

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
            extensionInFlight: keepPlayingExtensionInFlight)
        else { return }

        keepPlayingLastExtensionAttemptIndex = index
        keepPlayingExtensionInFlight = true
        keepPlayingExtensionTask?.cancel()
        keepPlayingExtensionTask = Task { [weak self] in
            await self?.performKeepPlayingExtension()
        }
    }

    private func currentKeepPlayingExclusions() -> Set<Int64> {
        Set(keepPlayingHistory).union(queue.compactMap { $0.track.id })
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
        let excluded = currentKeepPlayingExclusions()

        // A mood-seeded queue (docs/plans/mood-based-listening-plan.md §3.3/
        // §7) extends by re-running the SAME mood query, not the generic
        // last-played-track similarity `keepPlayingProvider` below — that
        // provider has no idea a mood query (prompt + pills) is even active.
        if case .mood(let source) = queueSource {
            source.setMatchingAnchor(keepPlayingHistory.last)
            let rows = await source.refreshedTracks()
            guard !Task.isCancelled else { return }
            let candidates = rows.filter { row in
                guard let id = row.track.id else { return false }
                return !excluded.contains(id)
            }
            guard !candidates.isEmpty else {
                await extendWithFallback(reason: .unavailable, excluding: excluded)
                return
            }
            finishKeepPlayingExtension(
                with: Array(candidates.prefix(keepPlayingBatchSize)), isFallback: false, reason: nil)
            return
        }

        if case .continuation(let source) = queueSource {
            let rows = await source.nextTracks(excluding: excluded, limit: keepPlayingBatchSize)
            guard !Task.isCancelled else { return }
            if !rows.isEmpty {
                finishKeepPlayingExtension(with: rows, isFallback: false, reason: nil)
            } else {
                await extendWithFallback(reason: .unavailable, excluding: excluded)
            }
            return
        }

        guard let provider = keepPlayingProvider else {
            await extendWithFallback(reason: .unavailable, excluding: excluded)
            return
        }

        // `keepPlayingHistory` is stored oldest-first; the provider wants
        // most-recently-played first so it can search against `.first`.
        let lookup = await provider.continuationTrackIDs(
            after: Array(keepPlayingHistory.reversed()), excluding: excluded,
            matchingTracksOnly: keepPlayingMatchingTracksOnly, limit: keepPlayingBatchSize)
        guard !Task.isCancelled else { return }
        switch lookup {
        case .ready(let ids) where !ids.isEmpty:
            // Defensive de-dup/no-repeat: the provider contract already says
            // it must exclude these, but Keep Playing's "never repeats
            // history or the just-played track" guarantee must hold even if
            // a provider implementation gets that wrong.
            let deduped = KeepPlayingPicker.dedupedCandidates(ids, excluding: excluded)
            guard !deduped.isEmpty else {
                await extendWithFallback(reason: .unavailable, excluding: excluded)
                return
            }
            await appendKeepPlayingSimilarTracks(deduped, isFallback: false, reason: nil)
        case .readyFromBroaderSimilarity(let ids) where !ids.isEmpty:
            let deduped = KeepPlayingPicker.dedupedCandidates(ids, excluding: excluded)
            guard !deduped.isEmpty else {
                await extendWithFallback(reason: .matchingUnavailable, excluding: excluded)
                return
            }
            await appendKeepPlayingSimilarTracks(
                deduped, isFallback: true, reason: .matchingUnavailable)
        case .ready:
            // The provider had nothing left after its own exclusions — a
            // real "no matches", not a bug — fall back honestly.
            await extendWithFallback(reason: .unavailable, excluding: excluded)
        case .readyFromBroaderSimilarity:
            await extendWithFallback(reason: .matchingUnavailable, excluding: excluded)
        case .waitingForModel:
            await extendWithFallback(reason: .waitingForModel, excluding: excluded)
        case .unavailable:
            await extendWithFallback(reason: .unavailable, excluding: excluded)
        }
    }

    /// Hydrates similarity-picked core track ids into `TrackRow`s and appends
    /// them. Falls back if none of the ids could be hydrated (e.g. a track was
    /// deleted between the lookup and now) rather than silently appending
    /// nothing.
    private func appendKeepPlayingSimilarTracks(
        _ ids: [Int64], isFallback: Bool, reason: KeepPlayingFallbackReason?
    ) async {
        var rows: [TrackRow] = []
        for id in ids {
            if let row = try? await LibraryStore.shared.trackRow(id: id) {
                rows.append(row)
            }
        }
        guard !Task.isCancelled else { return }
        guard !rows.isEmpty else {
            await extendWithFallback(reason: .unavailable, excluding: currentKeepPlayingExclusions())
            return
        }
        finishKeepPlayingExtension(with: rows, isFallback: isFallback, reason: reason)
    }

    /// The honest fallback: shuffle-continue from the same source/library
    /// scope already playing, never a silent no-op (CLAUDE.md "no silent/
    /// magic background work") — `keepPlayingLastExtensionWasFallback`/
    /// `keepPlayingFallbackReason` always record that this happened and why.
    private func extendWithFallback(reason: KeepPlayingFallbackReason, excluding excluded: Set<Int64>) async {
        let pool = await keepPlayingFallbackPool()
        guard !Task.isCancelled else { return }
        let candidates = pool.filter { row in
            guard let id = row.track.id else { return false }
            return !excluded.contains(id)
        }
        let picked = Array(candidates.shuffled().prefix(keepPlayingBatchSize))
        finishKeepPlayingExtension(with: picked, isFallback: true, reason: reason)
    }

    /// The candidate pool for the fallback shuffle-continue: whatever
    /// source/playlist/library scope this queue was actually started from —
    /// never a silently different scope than the one the user was playing
    /// from.
    private func keepPlayingFallbackPool() async -> [TrackRow] {
        switch queueSource {
        case .source(let source):
            guard let sourceId = source.id else { return (try? await LibraryStore.shared.allTrackRows()) ?? [] }
            return (try? await LibraryStore.shared.tracks(forSource: sourceId)) ?? []
        case .playlist(let playlist):
            guard let playlistId = playlist.id else { return (try? await LibraryStore.shared.allTrackRows()) ?? [] }
            return (try? await LibraryStore.shared.playlistItems(playlistId: playlistId)) ?? []
        case .library, .none, .mood, .continuation:
            // A mood queue's own extension is handled entirely above
            // (re-running the mood query) — this generic fallback pool is
            // only reached if that already failed, so the honest fallback
            // is the same "shuffle from everything" as .library/.none.
            return (try? await LibraryStore.shared.allTrackRows()) ?? []
        case .ambient:
            return []
        }
    }

    /// Appends the chosen rows (real similarity picks or fallback picks) to
    /// the live queue and records the outcome for the UI. Recording the
    /// outcome happens even when `rows` is empty — a fallback that found
    /// nothing to add is still a real, visible result, not silence.
    private func finishKeepPlayingExtension(
        with rows: [TrackRow], isFallback: Bool, reason: KeepPlayingFallbackReason?
    ) {
        keepPlayingLastExtensionWasFallback = isFallback
        keepPlayingFallbackReason = isFallback ? reason : nil
        // `next()` set this when it hit the end of the queue while this
        // extension was still running (real report: dead air after a mood
        // search's matches finish) — clear it either way, since the wait is
        // over regardless of whether it produced anything playable.
        let shouldResume = isWaitingForKeepPlayingToResume
        isWaitingForKeepPlayingToResume = false
        guard !rows.isEmpty else { return }

        queue.append(contentsOf: rows)
        if shuffle { unshuffledQueue = queue }
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
        if shouldResume, keepPlayingEnabled { next() }
    }

    /// Removes the not-yet-played auto-added tail from the queue — called
    /// when the user turns Keep Playing off, and exposed directly as the
    /// "Clear auto-added tracks" affordance. Already-played auto-added
    /// entries (before `index`) are left in the queue/history untouched.
    public func removeUnplayedKeepPlayingTracks() {
        guard !keepPlayingAutoAddedTrackIDs.isEmpty else { return }
        let offsets = queue.enumerated().compactMap { offset, row -> Int? in
            guard offset > index, let id = row.track.id, keepPlayingAutoAddedTrackIDs.contains(id)
            else { return nil }
            return offset
        }
        guard !offsets.isEmpty else { return }
        let removedIDs = Set(offsets.compactMap { queue[$0].track.id })
        removeFromQueue(atOffsets: IndexSet(offsets))
        keepPlayingAutoAddedTrackIDs.subtract(removedIDs)
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
