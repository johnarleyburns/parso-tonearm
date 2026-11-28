import Foundation
import TonearmCore

/// Keep Playing as an endless mix: from the last queued track, the next tracks
/// that Build a Mix's rules allow (±8% BPM, compatible Camelot key, energy as
/// a soft cost), chosen by the same planner — from the anchor's own genre when
/// that genre can continue, otherwise from the whole analysed library.
///
/// If no pair satisfies the strict rule, the nearest analysed tracks by BPM,
/// key and energy are used instead (still a musical pick, not a shuffle), and
/// the result says so so the UI can explain it honestly.
public actor KeepPlayingMixContinuation: KeepPlayingMixProviding {
    private let store: LibraryStore
    private var pool: [MixCandidate] = []
    private var genreByID: [Int64: String] = [:]
    private var loadedAt: Date?
    /// The library and its analysis change slowly; reload the pool at most this often.
    static let refreshInterval: TimeInterval = 600

    public init(store: LibraryStore) {
        self.store = store
    }

    public func mixContinuation(
        after trackID: Int64, excluding: Set<Int64>, limit: Int
    ) async -> KeepPlayingMixResult {
        guard limit > 0 else { return .empty }
        await refreshIfNeeded()
        guard let anchor = pool.first(where: { $0.trackID == trackID }) else { return .empty }
        let available = pool.filter { !excluding.contains($0.trackID) }
        let seed = UInt64(Date().timeIntervalSince1970 * 1_000)
        let averageLength = max(
            120,
            available.reduce(0) { $0 + max(0, $1.duration) }
                / Double(max(1, available.count)))
        func chain(_ candidates: [MixCandidate]) -> [Int64] {
            let plan = MixPlanner.plan(
                MixRequest(
                    candidates: candidates, shape: .steady,
                    targetDuration: averageLength * Double(limit + 1),
                    lockedFirst: trackID, seed: seed, compatibility: .standard))
            return Array(plan.steps.dropFirst().map(\.trackID).prefix(limit))
        }
        if let genre = genreByID[anchor.trackID], !genre.isEmpty {
            let sameGenre = available.filter { genreByID[$0.trackID] == genre }
            let ids = chain(sameGenre)
            if !ids.isEmpty { return KeepPlayingMixResult(trackIDs: ids, isRelaxed: false) }
        }
        let ids = chain(available)
        if !ids.isEmpty { return KeepPlayingMixResult(trackIDs: ids, isRelaxed: false) }
        return KeepPlayingMixResult(
            trackIDs: relaxedPicks(available, anchor: anchor, limit: limit), isRelaxed: true)
    }

    /// No strict pair exists. Rank every analysed candidate by how close it is
    /// to the anchor musically: BPM difference first, then Camelot relation,
    /// then energy. Missing BPM/key is still excluded (it cannot be mixed or
    /// explained), but nothing analysed is thrown away for being slightly
    /// outside ±8%.
    private func relaxedPicks(
        _ candidates: [MixCandidate], anchor: MixCandidate, limit: Int
    ) -> [Int64] {
        guard let anchorBPM = anchor.bpm, anchorBPM > 0, anchorBPM.isFinite,
            let anchorKey = anchor.camelot, !anchorKey.isEmpty
        else { return [] }
        return
            candidates
            .filter { $0.trackID != anchor.trackID }
            .compactMap { candidate -> (score: Double, id: Int64)? in
                guard let bpm = candidate.bpm, bpm > 0, bpm.isFinite,
                    let key = candidate.camelot, !key.isEmpty
                else { return nil }
                let bpmCost = abs(bpm / anchorBPM - 1) * 100
                let keyCost: Double
                if key == anchorKey {
                    keyCost = 0
                } else if MixCompatibility.keysCompatible(anchorKey, key) {
                    keyCost = 1
                } else {
                    keyCost = 6
                }
                let energyCost: Double
                if let energy = candidate.energy, let anchorEnergy = anchor.energy,
                    energy.isFinite, anchorEnergy.isFinite
                {
                    energyCost = abs(energy - anchorEnergy) / 2
                } else {
                    energyCost = 0
                }
                return (bpmCost + keyCost + energyCost, candidate.trackID)
            }
            .sorted {
                if $0.score != $1.score { return $0.score < $1.score }
                return $0.id < $1.id
            }
            .prefix(limit)
            .map(\.id)
    }

    private func refreshIfNeeded() async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.refreshInterval, !pool.isEmpty { return }
        guard let tracks = try? await store.allTracks() else { return }
        let ids = tracks.compactMap(\.id)
        let info = (try? await store.djLoadTrackInfo(trackIds: ids)) ?? [:]
        let energies = (try? await store.discoveryEnergies(trackIds: ids)) ?? [:]
        var candidates: [MixCandidate] = []
        var genres: [Int64: String] = [:]
        for track in tracks {
            guard let id = track.id, let bpm = info[id]?.bpm, let key = info[id]?.camelotKey,
                MixCompatibility.isCamelot(key)
            else { continue }
            candidates.append(
                MixCandidate(
                    trackID: id, bpm: bpm, camelot: key, energy: energies[id],
                    artist: track.artistId.map { "artist:\($0)" },
                    albumID: track.albumId, duration: track.durationSec ?? 0))
            if let genre = track.genre?.trimmingCharacters(in: .whitespaces) { genres[id] = genre }
        }
        pool = candidates
        genreByID = genres
        loadedAt = Date()
    }
}
