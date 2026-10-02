import Foundation
import TonearmCore

/// Keep Playing as an endless mix: from the last queued track, the next tracks that Build a Mix's
/// rules allow (±8% BPM, compatible Camelot key), chosen by the same planner — from the anchor's
/// own genre when that genre can continue, otherwise from the whole analysed library.
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

    public func mixContinuation(after trackID: Int64, excluding: Set<Int64>, limit: Int) async -> [Int64] {
        guard limit > 0 else { return [] }
        await refreshIfNeeded()
        guard let anchor = pool.first(where: { $0.trackID == trackID }) else { return [] }
        let available = pool.filter { $0.trackID == trackID || !excluding.contains($0.trackID) }
        let seed = UInt64(Date().timeIntervalSince1970 * 1_000)
        let averageLength = max(120, available.reduce(0) { $0 + max(0, $1.duration) } / Double(max(1, available.count)))
        func chain(_ candidates: [MixCandidate]) -> [Int64] {
            let plan = MixPlanner.plan(MixRequest(candidates: candidates, shape: .steady,
                                                  targetDuration: averageLength * Double(limit + 1),
                                                  lockedFirst: trackID, seed: seed, compatibility: .standard))
            return Array(plan.steps.dropFirst().map(\.trackID).prefix(limit))
        }
        if let genre = genreByID[anchor.trackID], !genre.isEmpty {
            let sameGenre = available.filter { genreByID[$0.trackID] == genre }
            let ids = chain(sameGenre)
            if !ids.isEmpty { return ids }
        }
        return chain(available)
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
                  MixCompatibility.isCamelot(key) else { continue }
            candidates.append(MixCandidate(trackID: id, bpm: bpm, camelot: key, energy: energies[id],
                                           artist: track.artistId.map { "artist:\($0)" },
                                           albumID: track.albumId, duration: track.durationSec ?? 0))
            if let genre = track.genre?.trimmingCharacters(in: .whitespaces) { genres[id] = genre }
        }
        pool = candidates
        genreByID = genres
        loadedAt = Date()
    }
}
