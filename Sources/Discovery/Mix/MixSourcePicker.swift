import Foundation
import TonearmCore

/// Where a Build a Mix session comes from.
public enum MixSource: Codable, Sendable, Equatable {
    /// One genre, chosen at random among genres with enough analysed music.
    case genre(String)
    /// An existing playlist, when no genre can fill the session.
    case playlist(id: Int64, title: String)
    /// The whole library from a random first track, when neither can.
    case library
    /// The caller chose the tracks (a playlist's "Mix This Playlist", mood results, a seed track).
    case given

    /// Key for the recent-mixes list ("not a playlist used in the past 10 mixes").
    public var historyKey: String? {
        switch self {
        case .genre(let name): "genre:\(name.lowercased())"
        case .playlist(let id, _): "playlist:\(id)"
        case .library, .given: nil
        }
    }
}

/// Chooses the source for a Build a Mix session and plans it under the mixing rules:
/// 1. a single genre, picked at random (genres not in recent mixes first) among genres whose
///    analysed tracks can fill the session;
/// 2. otherwise an existing playlist that wasn't used in the last 10 mixes;
/// 3. otherwise the whole library from a random first track.
/// A source is accepted only when its rule-following chain reaches 90% of the session length.
public enum MixSourcePicker {
    public struct Playlist: Sendable, Equatable {
        public let id: Int64
        public let title: String
        public let trackIDs: [Int64]
        public init(id: Int64, title: String, trackIDs: [Int64]) {
            self.id = id
            self.title = title
            self.trackIDs = trackIDs
        }
    }

    public static let recentLimit = 10
    static let acceptedFraction = 0.9
    /// A chain can dead-end from an unlucky first track; each source gets a few starting points.
    static let startsPerSource: UInt64 = 4

    public static func pick(candidates: [MixCandidate], genres: [Int64: String], playlists: [Playlist],
                            recentSources: [String], shape: MixShape, targetDuration: TimeInterval,
                            seed: UInt64, compatibility: MixCompatibility = .standard)
        -> (source: MixSource, plan: MixPlan) {
        let analysed = candidates.filter { candidate in
            (candidate.bpm ?? 0) > 0 && MixCompatibility.isCamelot(candidate.camelot ?? "")
        }
        let recent = Set(recentSources.suffix(recentLimit))
        func length(_ plan: MixPlan, _ pool: [MixCandidate]) -> TimeInterval {
            let durations: [Int64: TimeInterval] = Dictionary(pool.map { ($0.trackID, $0.duration) },
                                                              uniquingKeysWith: { first, _ in first })
            return plan.steps.reduce(0) { $0 + max(0, durations[$1.trackID] ?? 0) }
        }
        func plan(_ pool: [MixCandidate], attempt: UInt64 = 0) -> MixPlan {
            MixPlanner.plan(MixRequest(candidates: pool, shape: shape, targetDuration: targetDuration,
                                       seed: seed &+ attempt &* 0x5851_F42D_4C95_7F2D, compatibility: compatibility))
        }
        /// The first plan from this pool that fills the session, trying a few first tracks.
        func filling(_ pool: [MixCandidate]) -> MixPlan? {
            for attempt in 0..<startsPerSource {
                let candidatePlan = plan(pool, attempt: attempt)
                if length(candidatePlan, pool) >= targetDuration * acceptedFraction { return candidatePlan }
            }
            return nil
        }
        func order<T>(_ items: [T], key: (T) -> String) -> [T] {
            items.sorted { lhs, rhs in
                let l = recent.contains(key(lhs)), r = recent.contains(key(rhs))
                if l != r { return !l }
                return hash(key(lhs), seed) < hash(key(rhs), seed)
            }
        }

        // 1. One genre.
        var byGenre: [String: [MixCandidate]] = [:]
        for candidate in analysed {
            guard let genre = genres[candidate.trackID]?.trimmingCharacters(in: .whitespaces), !genre.isEmpty else { continue }
            byGenre[genre, default: []].append(candidate)
        }
        let eligibleGenres = byGenre.filter { $0.value.reduce(0) { $0 + max(0, $1.duration) } >= targetDuration }
        for genre in order(Array(eligibleGenres.keys), key: { MixSource.genre($0).historyKey ?? $0 }) {
            if let filled = filling(eligibleGenres[genre] ?? []) { return (.genre(genre), filled) }
        }

        // 2. An existing playlist not used in the last 10 mixes.
        let byID: [Int64: MixCandidate] = Dictionary(analysed.map { ($0.trackID, $0) },
                                                     uniquingKeysWith: { first, _ in first })
        let eligiblePlaylists = playlists.filter { playlist in
            !recent.contains(MixSource.playlist(id: playlist.id, title: playlist.title).historyKey ?? "")
        }
        for playlist in order(eligiblePlaylists, key: { "playlist:\($0.id)" }) {
            var seen = Set<Int64>()
            let pool = playlist.trackIDs.compactMap { id in seen.insert(id).inserted ? byID[id] : nil }
            guard pool.reduce(0, { $0 + max(0, $1.duration) }) >= targetDuration else { continue }
            if let filled = filling(pool) { return (.playlist(id: playlist.id, title: playlist.title), filled) }
        }

        // 3. The whole library from a random first track.
        return (.library, plan(analysed))
    }

    /// A mix from a pool the listener chose (one genre, one playlist, or all tracks): under the
    /// mixing rules, the first of a few starting points that fills the session, else the longest.
    public static func plan(pool candidates: [MixCandidate], shape: MixShape, targetDuration: TimeInterval,
                            seed: UInt64, compatibility: MixCompatibility = .standard) -> MixPlan {
        var seen = Set<Int64>()
        let pool = candidates.filter { candidate in
            (candidate.bpm ?? 0) > 0 && MixCompatibility.isCamelot(candidate.camelot ?? "")
                && seen.insert(candidate.trackID).inserted
        }
        let durations = Dictionary(pool.map { ($0.trackID, $0.duration) }, uniquingKeysWith: { first, _ in first })
        func length(_ plan: MixPlan) -> TimeInterval {
            plan.steps.reduce(0) { $0 + max(0, durations[$1.trackID] ?? 0) }
        }
        var best: MixPlan?
        for attempt in 0..<startsPerSource {
            let candidatePlan = MixPlanner.plan(MixRequest(
                candidates: pool, shape: shape, targetDuration: targetDuration,
                seed: seed &+ attempt &* 0x5851_F42D_4C95_7F2D, compatibility: compatibility))
            if length(candidatePlan) >= targetDuration * acceptedFraction { return candidatePlan }
            if best.map({ length(candidatePlan) > length($0) }) ?? true { best = candidatePlan }
        }
        return best ?? MixPlanner.plan(MixRequest(candidates: pool, shape: shape, targetDuration: targetDuration,
                                                  seed: seed, compatibility: compatibility))
    }

    /// Stable seeded order (FNV-1a over the key, mixed with the seed).
    static func hash(_ key: String, _ seed: UInt64) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325 ^ (seed &* 0x9E37_79B9_7F4A_7C15)
        for byte in key.utf8 {
            value ^= UInt64(byte)
            value &*= 0x0000_0100_0000_01B3
        }
        return value
    }
}
