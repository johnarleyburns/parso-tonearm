import Foundation
import GRDB
import TonearmCore

/// Interactions (§28A.4): reject / replace / extend / reshuffle / save-as-playlist,
/// each a constrained re-run over the last resolved pool rather than a fresh roll
/// of the dice. Split out of `PlaylistGenerator.swift`; uses the actor's shared
/// `lastRequest`/`lastBriefID`/`lastCandidates`/`lastSlots`/`lastSemanticScores`
/// state (declared `internal` there for exactly this cross-file use).
extension PlaylistGenerator {
    /// Reject a track: row it into `auto_playlist_rejection` against the brief,
    /// then re-run with the remaining locks intact — so the second generation is
    /// visibly better than the first (plan §2.7).
    public func reject(trackID: Int64) async throws -> PlaylistGeneration {
        guard let request = lastRequest, let briefID = lastBriefID else {
            throw PlaylistGeneratorError.noGeneration
        }
        try repository.upsertRejections(briefID: briefID, trackIDs: [trackID])
        return try await generate(request)
    }

    /// Replace one slot: swap in the best candidate that minimises
    /// `transitionCost(prev, x) + transitionCost(x, next) + arcError(x)`,
    /// holding neighbours fixed and re-validating spacing (§28A.4). Sub-ms.
    public func replaceSlot(slot: Int) async throws -> PlaylistGeneration {
        guard let request = lastRequest, let candidates = lastCandidates,
              let slots = lastSlots, let semanticScores = lastSemanticScores else {
            throw PlaylistGeneratorError.noGeneration
        }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.trackID, $0) })
        let tracks = slots.compactMap { byID[$0.trackID] }
        guard slot >= 0, slot < tracks.count else { throw PlaylistGeneratorError.noGeneration }

        let current = tracks[slot]
        let used = Set(tracks.map(\.trackID)).subtracting([current.trackID])
        var rng = SplitMix64(seed: request.randomSeed
            &+ UInt64(bitPattern: Int64(slot)) &* 0x9E37_79B9_7F4A_7C15)
        var best: (track: TrackFeatures, cost: Double, tie: UInt64)?

        for candidate in candidates
        where !used.contains(candidate.trackID) && candidate.trackID != current.trackID
            && !request.locks.values.contains(candidate.trackID) {
            var trial = tracks
            trial[slot] = candidate
            guard PlaylistSequencer.validateSpacing(trial, constraints: request.constraints) else {
                continue
            }
            var cost = PlaylistSequencer.arcError(
                energy: candidate.energy ?? PlaylistSequencer.neutral,
                position: slot, count: tracks.count, arc: request.arc)
            if slot > 0 {
                cost += PlaylistSequencer.transitionCost(tracks[slot - 1], candidate,
                                                         request.constraints)
            }
            if slot < tracks.count - 1 {
                cost += PlaylistSequencer.transitionCost(candidate, tracks[slot + 1],
                                                         request.constraints)
            }
            let tie = rng.next()
            if let existing = best {
                if cost < existing.cost || (cost == existing.cost && tie < existing.tie) {
                    best = (candidate, cost, tie)
                }
            } else {
                best = (candidate, cost, tie)
            }
        }
        guard let chosen = best else { throw PlaylistGeneratorError.noGeneration }

        var newTracks = tracks
        newTracks[slot] = chosen.track
        let newSlots = makeSlots(tracks: newTracks, request: request,
                                 semanticScores: semanticScores)
        let result = makeResult(slots: newSlots, candidates: newTracks, request: request)
        let items = makeItems(slots: newSlots, locks: request.locks)
        let persisted = try await persist(request: request, result: result, items: items)

        lastRequest = request
        lastBriefID = persisted.brief.id
        lastSlots = newSlots
        lastSemanticScores = semanticScores
        return PlaylistGeneration(brief: persisted.brief,
                                  result: persisted.result,
                                  items: persisted.items,
                                  requestedCount: newTracks.count,
                                  candidateCount: candidates.count,
                                  isShortPool: false)
    }

    /// Extend by `minutes`: the arc is re-parameterised over the new length
    /// (§28A.4), so extending a wind-down continues it rather than restarting it.
    public func extend(minutes: Int) async throws -> PlaylistGeneration {
        guard var request = lastRequest else { throw PlaylistGeneratorError.noGeneration }
        request.targetSeconds = (request.targetSeconds ?? 0) + Double(max(minutes, 1)) * 60
        return try await generate(request)
    }

    /// Reshuffle the middle: re-run the beam over `[from, to]` with the tracks
    /// outside it fixed as endpoints, on a fresh seed so the middle varies (§28A.4).
    public func reshuffle(from: Int, to: Int) async throws -> PlaylistGeneration {
        guard var request = lastRequest, let slots = lastSlots else {
            throw PlaylistGeneratorError.noGeneration
        }
        let lower = max(0, min(from, slots.count - 1))
        let upper = max(lower, min(to, slots.count - 1))
        var locks = request.locks
        for (index, slot) in slots.enumerated() where index < lower || index > upper {
            locks[index] = slot.trackID
        }
        request.locks = locks
        var rng = SplitMix64(seed: request.randomSeed)
        request.randomSeed = rng.next()
        return try await generate(request)
    }

    /// Save the latest sequence as a static playlist (FR-PLIST-7); links it on
    /// the brief's latest result and returns the new playlist id.
    @discardableResult
    public func saveAsPlaylist(title: String) async throws -> Int64 {
        guard let briefID = lastBriefID, let slots = lastSlots else {
            throw PlaylistGeneratorError.noGeneration
        }
        return try repository.savePlaylist(title: title, briefID: briefID, slots: slots)
    }
}
