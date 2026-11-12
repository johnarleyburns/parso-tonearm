import Foundation

/// Pure "Keep Playing" selection logic, factored out of `AudioPlayer` so it's
/// testable without a live player/queue/`LibraryStore` — the same reason
/// `QueueEditor` exists as a static namespace over plain queue state rather
/// than living as private logic inside `AudioPlayer` itself.
public enum KeepPlayingPicker {
    /// Maximum number of unplayed auto (`.keepPlaying`) entries the queue holds ahead of playback.
    public static let autoRecommendationHorizon = 10
    /// Refill once the unplayed auto tail has shrunk to this many entries (when at least one remains).
    public static let refillWhenUnplayedAutoCountAtMost = 3
    /// Documented diversity policy: the lookback is the current track plus the 2 preceding entries.
    public static let maxSameArtistInLookback = 2
    public static let maxSameAlbumInLookback = 3
    static let lookbackSize = 3

    /// How many more auto entries may be appended right now.
    public static func horizonBudget(unplayedAutoCount: Int) -> Int {
        max(0, autoRecommendationHorizon - unplayedAutoCount)
    }

    /// A candidate reduced to the identity the diversity rules need.
    public struct Candidate: Equatable, Sendable {
        public var id: Int64
        public var artist: String?
        public var album: String?
        public init(id: Int64, artist: String? = nil, album: String? = nil) {
            self.id = id
            self.artist = artist
            self.album = album
        }
    }

    public struct Plan: Equatable, Sendable {
        public var picks: [Candidate]
        /// Internal diagnostics only: set when diversity had to be relaxed for at least one pick.
        public var relaxedAlbum = false
        public var relaxedArtist = false
    }

    private static func key(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Picks up to `budget` candidates in provider order. Each pick must avoid the artist and album
    /// of the lookback window (current + preceding two entries, sliding as picks are added); if none
    /// qualifies, album is relaxed first, then artist. Ids in `excluded` are never chosen.
    public static func plan(
        candidates: [Candidate], excluded: Set<Int64>, lookback: [Candidate], budget: Int
    ) -> Plan {
        var plan = Plan(picks: [])
        guard budget > 0 else { return plan }
        var remaining = dedupedCandidates(candidates.map(\.id), excluding: excluded).compactMap { id in
            candidates.first { $0.id == id }
        }
        var window = Array(lookback.suffix(lookbackSize))
        while plan.picks.count < budget, !remaining.isEmpty {
            let artists = Set(window.compactMap { key($0.artist) })
            let albums = Set(window.compactMap { key($0.album) })
            func artistOK(_ c: Candidate) -> Bool { key(c.artist).map { !artists.contains($0) } ?? true }
            func albumOK(_ c: Candidate) -> Bool { key(c.album).map { !albums.contains($0) } ?? true }
            let index: Int
            if let i = remaining.firstIndex(where: { artistOK($0) && albumOK($0) }) {
                index = i
            } else if let i = remaining.firstIndex(where: artistOK) {
                index = i
                plan.relaxedAlbum = true
            } else {
                index = 0
                plan.relaxedAlbum = true
                plan.relaxedArtist = true
            }
            let pick = remaining.remove(at: index)
            plan.picks.append(pick)
            window.append(pick)
            window = Array(window.suffix(lookbackSize))
        }
        return plan
    }

    /// Whether the manually-built queue is close enough to running out that
    /// Keep Playing should attempt an extension right now. Mirrors exactly
    /// what `AudioPlayer.maybeExtendKeepPlayingQueue()` gates on.
    public static func shouldAttemptExtension(
        enabled: Bool,
        isAmbient: Bool,
        repeatMode: RepeatMode,
        queueCount: Int,
        index: Int,
        lastAttemptedIndex: Int?,
        extensionInFlight: Bool,
        unplayedAutoCount: Int = 0
    ) -> Bool {
        guard enabled, !isAmbient else { return false }
        // `.all` loops the existing queue forever and `.one` never advances
        // past the current track — neither can ever "run out".
        guard repeatMode == .off else { return false }
        guard index >= 0, index < queueCount else { return false }
        guard horizonBudget(unplayedAutoCount: unplayedAutoCount) > 0 else { return false }
        // At most two ordinary (non-auto) future entries remain, or the auto tail is running low.
        // An empty auto tail alone never triggers: ordinary entries must be nearly exhausted.
        let nonAutoFuture = queueCount - index - 1 - unplayedAutoCount
        let ordinaryLow = nonAutoFuture <= 2
        let autoLow = unplayedAutoCount > 0 && unplayedAutoCount <= refillWhenUnplayedAutoCountAtMost
        guard ordinaryLow || autoLow else { return false }
        guard lastAttemptedIndex != index else { return false }
        guard !extensionInFlight else { return false }
        return true
    }

    /// Filters a similarity provider's raw candidate ids down to the ones
    /// Keep Playing may actually use: never something already excluded
    /// (this session's play history, or a track already sitting in the live
    /// queue), and never a duplicate within the candidate list itself — a
    /// defense against a misbehaving provider, not just documentation of the
    /// protocol's contract. Order is preserved (best match first).
    public static func dedupedCandidates(_ ids: [Int64], excluding: Set<Int64>) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { id in
            guard !excluding.contains(id), seen.insert(id).inserted else { return false }
            return true
        }
    }
}
