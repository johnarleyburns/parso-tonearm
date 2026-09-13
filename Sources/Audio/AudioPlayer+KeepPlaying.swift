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
        after recentlyPlayed: [Int64], excluding: Set<Int64>, limit: Int
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
        Task { [weak self] in
            await self?.performKeepPlayingExtension()
        }
    }

    private func currentKeepPlayingExclusions() -> Set<Int64> {
        Set(keepPlayingHistory).union(queue.compactMap { $0.track.id })
    }

    private func performKeepPlayingExtension() async {
        defer { keepPlayingExtensionInFlight = false }
        let excluded = currentKeepPlayingExclusions()

        guard let provider = keepPlayingProvider else {
            await extendWithFallback(reason: .unavailable, excluding: excluded)
            return
        }

        // `keepPlayingHistory` is stored oldest-first; the provider wants
        // most-recently-played first so it can search against `.first`.
        let lookup = await provider.continuationTrackIDs(
            after: Array(keepPlayingHistory.reversed()), excluding: excluded, limit: keepPlayingBatchSize)
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
            await appendKeepPlayingSimilarTracks(deduped)
        case .ready:
            // The provider had nothing left after its own exclusions — a
            // real "no matches", not a bug — fall back honestly.
            await extendWithFallback(reason: .unavailable, excluding: excluded)
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
    private func appendKeepPlayingSimilarTracks(_ ids: [Int64]) async {
        var rows: [TrackRow] = []
        for id in ids {
            if let row = try? await LibraryStore.shared.trackRow(id: id) {
                rows.append(row)
            }
        }
        guard !rows.isEmpty else {
            await extendWithFallback(reason: .unavailable, excluding: currentKeepPlayingExclusions())
            return
        }
        finishKeepPlayingExtension(with: rows, isFallback: false, reason: nil)
    }

    /// The honest fallback: shuffle-continue from the same source/library
    /// scope already playing, never a silent no-op (CLAUDE.md "no silent/
    /// magic background work") — `keepPlayingLastExtensionWasFallback`/
    /// `keepPlayingFallbackReason` always record that this happened and why.
    private func extendWithFallback(reason: KeepPlayingFallbackReason, excluding excluded: Set<Int64>) async {
        let pool = await keepPlayingFallbackPool()
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
        case .library, .none:
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
        guard !rows.isEmpty else { return }

        queue.append(contentsOf: rows)
        if shuffle { unshuffledQueue = queue }
        for row in rows {
            if let id = row.track.id { keepPlayingAutoAddedTrackIDs.insert(id) }
        }
        prefetchNext()
        preloadNextItem()
        persist(reason: .transportEvent)
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
