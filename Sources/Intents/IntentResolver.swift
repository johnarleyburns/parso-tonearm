import Foundation

public enum IntentResolver {
    public enum TargetKind: String, Equatable {
        case playlist
        case artist
        case sourceURL
        case sleepTimer
    }

    public enum Failure: Equatable {
        case emptyLibrary(TargetKind)
        case emptyParameter(TargetKind)
        case noMatch(kind: TargetKind, query: String)
        case ambiguous(kind: TargetKind, query: String, matches: [String])
        case malformedURL(String)
        case invalidSleepTimerMinutes(Int)
    }

    public enum SleepTimerPlan: Equatable {
        case minutes(Int)
        case endOfTrack
        case cancel
    }

    public enum Command: Equatable {
        case playPlaylist(id: Int64, title: String)
        case playArtist(name: String)
        case resume
        case setSleepTimer(SleepTimerPlan)
        case addSource(rawURL: String)
    }

    public enum Resolution: Equatable {
        case command(Command)
        case failure(Failure)
    }

    public struct PlaylistCandidate: Equatable {
        var id: Int64
        var title: String
    }

    public struct ArtistCandidate: Equatable {
        var name: String
    }

    private struct NamedCandidate: Equatable {
        var id: String
        var name: String
    }

    public static let minimumSleepMinutes = 1
    public static let maximumSleepMinutes = 8 * 60

    public static func resolvePlaylist(
        named query: String,
        playlists: [PlaylistCandidate]
    ) -> Resolution {
        let candidates = playlists.map { NamedCandidate(id: String($0.id), name: $0.title) }
        switch match(query: query, candidates: candidates, kind: .playlist) {
        case .matched(let candidate):
            guard let id = Int64(candidate.id) else {
                return .failure(.noMatch(kind: .playlist, query: query))
            }
            return .command(.playPlaylist(id: id, title: candidate.name))
        case .failed(let failure):
            return .failure(failure)
        }
    }

    public static func resolveArtist(
        named query: String,
        artists: [ArtistCandidate]
    ) -> Resolution {
        let candidates = artists.map { NamedCandidate(id: $0.name, name: $0.name) }
        switch match(query: query, candidates: candidates, kind: .artist) {
        case .matched(let candidate):
            return .command(.playArtist(name: candidate.name))
        case .failed(let failure):
            return .failure(failure)
        }
    }

    public static func resolveResume() -> Resolution {
        .command(.resume)
    }

    public static func resolveSleepTimer(minutes: Int) -> Resolution {
        guard minutes >= minimumSleepMinutes, minutes <= maximumSleepMinutes else {
            return .failure(.invalidSleepTimerMinutes(minutes))
        }
        return .command(.setSleepTimer(.minutes(minutes)))
    }

    public static func resolveSleepTimerEndOfTrack() -> Resolution {
        .command(.setSleepTimer(.endOfTrack))
    }

    public static func resolveSleepTimerCancel() -> Resolution {
        .command(.setSleepTimer(.cancel))
    }

    public static func resolveAddSource(rawURL: String) -> Resolution {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.emptyParameter(.sourceURL))
        }
        guard case .success = URLGrammar.parse(trimmed) else {
            return .failure(.malformedURL(trimmed))
        }
        return .command(.addSource(rawURL: trimmed))
    }

    private enum MatchResult: Equatable {
        case matched(NamedCandidate)
        case failed(Failure)
    }

    private static func match(
        query: String,
        candidates: [NamedCandidate],
        kind: TargetKind
    ) -> MatchResult {
        guard !candidates.isEmpty else {
            return .failed(.emptyLibrary(kind))
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failed(.emptyParameter(kind))
        }

        let normalizedQuery = StringSimilarity.normalize(trimmed)
        guard !normalizedQuery.isEmpty else {
            return .failed(.emptyParameter(kind))
        }

        let exact = candidates.filter { StringSimilarity.normalize($0.name) == normalizedQuery }
        if let result = singleOrAmbiguous(exact, kind: kind, query: trimmed) {
            return result
        }

        let contains = candidates.filter { candidate in
            let normalizedName = StringSimilarity.normalize(candidate.name)
            return normalizedName.contains(normalizedQuery)
                || StringSimilarity.tokensContained(needle: trimmed, in: candidate.name)
        }
        if let result = singleOrAmbiguous(contains, kind: kind, query: trimmed) {
            return result
        }

        let fuzzy = candidates.filter { StringSimilarity.ratio(trimmed, $0.name) >= 0.9 }
        if let result = singleOrAmbiguous(fuzzy, kind: kind, query: trimmed) {
            return result
        }

        return .failed(.noMatch(kind: kind, query: trimmed))
    }

    private static func singleOrAmbiguous(
        _ matches: [NamedCandidate],
        kind: TargetKind,
        query: String
    ) -> MatchResult? {
        if matches.count == 1 {
            return .matched(matches[0])
        }
        if matches.count > 1 {
            return .failed(.ambiguous(
                kind: kind,
                query: query,
                matches: matches.map(\.name)
            ))
        }
        return nil
    }
}
