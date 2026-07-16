import Foundation

/// iTunes Search API response models (subset we use).
public struct ITunesResponse: Decodable {
    public let results: [ITunesResult]
}

public struct ITunesResult: Decodable, Equatable {
    public let wrapperType: String?
    public let collectionType: String?
    public let artistName: String?
    public let collectionName: String?
    public let trackName: String?
    public let artworkUrl100: String?
    public let trackCount: Int?
}

/// The chosen artwork plus whether the match is strong enough to remember.
public struct ArtworkMatch: Equatable {
    public let artworkURL: URL
    /// Strong matches (artist AND album/track align) may be persisted as the
    /// source's remembered representative; weak matches are shown but provisional.
    public let isStrong: Bool
}

public enum ArtworkSearchError: Error, LocalizedError {
    case disallowedHost(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .disallowedHost(let h): return "Refusing to contact non-allowlisted host: \(h)"
        case .badResponse: return "Unexpected response from artwork search"
        }
    }
}

/// Looks up missing album/track artwork via Apple's iTunes Search API. This is the
/// ONLY sanctioned non-archive.org network egress in the app; it keeps its own host
/// allowlist so the archive.org-only guarantee for `IAClient` is unaffected.
public actor ArtworkSearchClient {
    public static let shared = ArtworkSearchClient()

    private let session: URLSession
    private let userAgent: String

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 12
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        userAgent = "Tonearm/\(version) (parso.guru)"
    }

    // MARK: - Host allowlist (mirrors IAClient posture, distinct hosts)

    public static func isAllowedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "itunes.apple.com"
            || h == "mzstatic.com" || h.hasSuffix(".mzstatic.com")
    }

    // MARK: - Public lookup

    /// Resolves artwork for the given (optionally tagged) metadata, applying the
    /// fuzzy query chain and confidence gate. Returns nil when nothing clears the floor.
    public func artwork(artist: String?, album: String?, trackTitle: String?) async -> ArtworkMatch? {
        let effArtist: String?
        let effTitle: String?
        let cleanedTerm: String

        if let taggedArtist = artist?.nonBlank {
            // Tagged (IA or well-tagged local): trust the metadata as-is.
            effArtist = taggedArtist
            effTitle = trackTitle?.nonBlank
            cleanedTerm = [taggedArtist, trackTitle?.nonBlank].compactMap { $0 }.joined(separator: " ")
        } else {
            // Untagged local file: parse the (possibly messy) filename/title.
            let parsed = FilenameQueryParser().parse(trackTitle ?? "")
            effArtist = parsed.artist
            effTitle = parsed.title
            cleanedTerm = parsed.cleanedTerm
        }
        let effAlbum = album?.nonBlank

        guard effArtist != nil || effAlbum != nil || !cleanedTerm.isEmpty else {
            return nil
        }

        // Stage 1: tagged album -> album search.
        if let a = effArtist, let alb = effAlbum {
            if let match = await searchAlbum(term: "\(a) \(alb)", artist: a, album: alb) {
                return match
            }
        }
        // Stage 2: artist + title -> track search.
        if let a = effArtist, let t = effTitle {
            if let match = await searchTrack(term: "\(a) \(t)", artist: a, title: t) {
                return match
            }
        }
        // Stage 3: artist-only / single keyword -> artistTerm album search.
        if let a = effArtist {
            if let match = await searchArtistAlbums(artist: a) {
                return match
            }
        }
        // Stage 4: last resort -> plain track term search.
        if !cleanedTerm.isEmpty {
            if let match = await searchTrack(term: cleanedTerm,
                                             artist: effArtist ?? cleanedTerm,
                                             title: effTitle) {
                return match
            }
        }
        return nil
    }

    // MARK: - Stage searches

    private func searchAlbum(term: String, artist: String, album: String?) async -> ArtworkMatch? {
        guard let url = Self.searchURL(term: term, entity: "album") else { return nil }
        let results = await fetchResults(url)
        return Self.bestMatch(from: results, queryArtist: artist, queryTitle: album)
    }

    private func searchTrack(term: String, artist: String, title: String?) async -> ArtworkMatch? {
        guard let url = Self.searchURL(term: term, entity: "musicTrack") else { return nil }
        let results = await fetchResults(url)
        return Self.bestMatch(from: results, queryArtist: artist, queryTitle: title)
    }

    private func searchArtistAlbums(artist: String) async -> ArtworkMatch? {
        guard let url = Self.searchURL(term: artist, entity: "album", attribute: "artistTerm") else { return nil }
        let results = await fetchResults(url)
        return Self.bestMatch(from: results, queryArtist: artist, queryTitle: nil)
    }

    // MARK: - Networking

    private func fetchResults(_ url: URL) async -> [ITunesResult] {
        guard let host = url.host, Self.isAllowedHost(host) else { return [] }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(ITunesResponse.self, from: data) else {
            return []
        }
        return decoded.results
    }

    /// Downloads image bytes for a resolved artwork URL, enforcing the allowlist.
    public func imageData(from url: URL) async throws -> Data {
        guard let host = url.host, Self.isAllowedHost(host) else {
            throw ArtworkSearchError.disallowedHost(url.host ?? "unknown")
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ArtworkSearchError.badResponse
        }
        return data
    }

    // MARK: - URL building

    public static func searchURL(term: String, entity: String, attribute: String? = nil,
                          limit: Int = 5) -> URL? {
        var comps = URLComponents(string: "https://itunes.apple.com/search")
        var items = [
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "term", value: term)
        ]
        if let attribute { items.append(URLQueryItem(name: "attribute", value: attribute)) }
        comps?.queryItems = items
        return comps?.url
    }

    /// Upscales an `artworkUrl100` (…/100x100bb.jpg) to a larger square.
    public static func upscaledArtworkURL(_ raw: String, size: Int = 600) -> URL? {
        let replaced = raw.replacingOccurrences(of: "100x100bb", with: "\(size)x\(size)bb")
        return URL(string: replaced)
    }

    // MARK: - Confidence gate (pure, unit-tested)

    /// Chooses the best result requiring artist-token alignment. Title/collection
    /// matches alone never qualify. Returns nil when nothing clears the floor.
    public static func bestMatch(from results: [ITunesResult], queryArtist: String,
                          queryTitle: String?) -> ArtworkMatch? {
        var best: (score: Double, strong: Bool, url: URL)?

        for r in results {
            guard let artistName = r.artistName,
                  let art100 = r.artworkUrl100,
                  let url = upscaledArtworkURL(art100) else { continue }

            // REQUIRED: at least half the query-artist tokens must appear within
            // the result's artistName, so legitimate matches survive extra noise
            // tokens (city/venue names, qualifiers) that the parser couldn't strip.
            let artistOverlap = StringSimilarity.tokenOverlap(needle: queryArtist, haystack: artistName)
            guard artistOverlap >= 0.5 else { continue }

            var score = artistOverlap

            // Penalize collab / compilation unless the query itself asked for it.
            let lowerArtist = artistName.lowercased()
            let queryWantsCollab = queryArtist.lowercased().contains("&")
                || queryArtist.lowercased().contains("feat")
            if !queryWantsCollab {
                if lowerArtist.contains(" & ") || lowerArtist.contains(" feat") { score -= 0.25 }
                if lowerArtist == "various artists" { score -= 0.5 }
            }

            // Reward album over single, and title alignment when we have a title.
            let title = r.trackName ?? r.collectionName
            var titleAligns = false
            if let queryTitle, let title {
                let tr = StringSimilarity.tokenOverlap(needle: queryTitle, haystack: title)
                if tr >= 0.6 { titleAligns = true; score += 0.3 }
                // Prefer the closest title (exact "Boavista" over "Boavista (Synthapella)").
                score += StringSimilarity.ratio(queryTitle, title) * 0.2
            }
            if r.collectionType == "Album", (r.trackCount ?? 1) > 1 { score += 0.1 }

            // Strong = artist aligns AND (a title was requested and aligns,
            // or no title was requested but artist match is essentially exact).
            let artistExact = StringSimilarity.ratio(queryArtist, artistName) >= 0.9
            let strong: Bool
            if queryTitle != nil {
                strong = titleAligns
            } else {
                strong = artistExact && !(lowerArtist.contains(" & ") && !queryWantsCollab)
            }

            if best == nil || score > best!.score {
                best = (score, strong, url)
            }
        }

        guard let picked = best, picked.score > 0 else { return nil }
        return ArtworkMatch(artworkURL: picked.url, isStrong: picked.strong)
    }
}

private extension String {
    var nonBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
