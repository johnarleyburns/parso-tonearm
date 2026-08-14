import Foundation

/// M5 commit 5.6 — the genre-library connector (§18A, plan 5.6, FR-LIB-9/10).
///
/// A **genre library** inverts the unit of subscription: instead of connecting
/// a server, the user subscribes to a genre and gets a ready-made, ordered
/// crate of legally usable (Creative-Commons) tracks. Each genre is an ordinary
/// `Source(kind: .jamendoGenre, iaIdentifier: <genre path>)` row, so
/// everything downstream — caching, analysis, search, playlists, decks — works
/// with no special-casing (§18A.3).
///
/// **The catalogue is the Jamendo API** (`api.jamendo.com/v3.0`). The Free
/// Music Archive was the original candidate and cannot be used: FMA shut down
/// their public API and their terms prohibit hotlinked playback and scraped
/// browsing — the two things this feature needs (§18A.2, plan decision 20).
///
/// **Verified against the live API at implementation time** (plan decision 20 —
/// "endpoint shapes MUST be verified, not assumed"): the *only* read methods
/// Jamendo exposes are `albums`, `artists`, `autocomplete`, `feeds`,
/// `playlists`, `radios`, `reviews`, `tracks`, `users` — there is **no
/// `/v3.0/genres` method** (`GET /v3.0/genres` returns code 7, "no method is
/// represented by this url part: genres"). Genre data is free-form
/// `musicinfo.tags.genres` on tracks, filtered through the `tags` parameter.
/// The hierarchy is therefore **curated here** (`JamendoGenreTree`) and each
/// node filters the catalogue by its tag.
///
/// `client_id` is an **application credential, not a user login** (FR-LIB-9's
/// "works with no account" holds). It is read from the app's Info.plist
/// (`JamendoClientID`, `JamendoAppConfig`) and registered by the owner on the
/// same checklist as the Plex claim token (§50.3). Until it exists, the
/// provider reports an honest unavailable state — never an empty-looking
/// library (§18A.6).
public enum JamendoGenreError: LocalizedError, Equatable, Sendable {
    /// No application `client_id` is configured in this build.
    case notConfigured
    /// A transport / HTTP failure reaching the catalogue.
    case transport
    /// The API returned a failure envelope (`headers.code != 0`).
    case catalogue(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Jamendo isn't configured in this build yet."
        case .transport:
            return "Couldn't reach the Jamendo catalogue."
        case .catalogue(let message):
            return "The Jamendo catalogue returned an error: \(message)"
        }
    }
}

/// The application-level Jamendo configuration. `client_id` is an application
/// credential — it travels in the build and is read from the app's Info.plist,
/// exactly like the OAuth client IDs. It is not a user login (§18A.2).
public enum JamendoAppConfig {
    public static var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "JamendoClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// One node of the curated genre hierarchy. `path` is the §18A.3 source
/// identity (`electronic/techno`); `tag` is the Jamendo `tags` filter used to
/// fetch that library and is always the last path component — so the top-level
/// `electronic` and its child `techno` are genuinely different libraries.
public struct JamendoGenreNode: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let tag: String
    public let children: [JamendoGenreNode]

    public init(name: String, path: String, children: [JamendoGenreNode] = []) {
        self.name = name
        self.path = path
        self.tag = String(path.split(separator: "/").last ?? Substring(path))
        self.children = children
    }
}

/// The curated genre hierarchy (mockup `ipad/15-genre-picker.html` §41.1a).
/// Jamendo exposes no taxonomy endpoint, so the tree is curated here; each tag
/// is a real Jamendo genre tag used in the `tags` filter (§18A.3).
public enum JamendoGenreTree {
    public static let roots: [JamendoGenreNode] = [
        .init(name: "Electronic", path: "electronic", children: [
            .init(name: "Techno", path: "electronic/techno"),
            .init(name: "House", path: "electronic/house"),
            .init(name: "Drum & Bass", path: "electronic/drum-and-bass"),
            .init(name: "Ambient", path: "electronic/ambient"),
            .init(name: "Breakbeat", path: "electronic/breakbeat"),
            .init(name: "Dubstep", path: "electronic/dubstep"),
        ]),
        .init(name: "Hip-Hop", path: "hip-hop", children: [
            .init(name: "Boom Bap", path: "hip-hop/boom-bap"),
            .init(name: "Trap", path: "hip-hop/trap"),
            .init(name: "Instrumental", path: "hip-hop/instrumental"),
            .init(name: "Lo-fi", path: "hip-hop/lo-fi"),
            .init(name: "Alternative", path: "hip-hop/alternative"),
        ]),
        .init(name: "Rock", path: "rock", children: [
            .init(name: "Indie", path: "rock/indie"),
            .init(name: "Punk", path: "rock/punk"),
            .init(name: "Post-Rock", path: "rock/post-rock"),
            .init(name: "Garage", path: "rock/garage"),
        ]),
        .init(name: "Jazz", path: "jazz", children: [
            .init(name: "Nu-Jazz", path: "jazz/nu-jazz"),
            .init(name: "Free Jazz", path: "jazz/free-jazz"),
            .init(name: "Swing", path: "jazz/swing"),
        ]),
        .init(name: "Soul · Funk", path: "soul", children: [
            .init(name: "Funk", path: "soul/funk"),
            .init(name: "Disco", path: "soul/disco"),
            .init(name: "R&B", path: "soul/r-and-b"),
        ]),
        .init(name: "Pop", path: "pop", children: [
            .init(name: "Synth Pop", path: "pop/synth-pop"),
            .init(name: "Dream Pop", path: "pop/dream-pop"),
        ]),
        .init(name: "International", path: "world", children: [
            .init(name: "Afrobeat", path: "world/afrobeat"),
            .init(name: "Latin", path: "world/latin"),
            .init(name: "Balkan", path: "world/balkan"),
        ]),
        .init(name: "Experimental", path: "experimental", children: [
            .init(name: "Noise", path: "experimental/noise"),
            .init(name: "Drone", path: "experimental/drone"),
            .init(name: "Musique Concrète", path: "experimental/musique-concrete"),
        ]),
    ]

    /// Flatten every selectable node in the tree (parents and children).
    public static var all: [JamendoGenreNode] {
        var out: [JamendoGenreNode] = []
        func walk(_ nodes: [JamendoGenreNode]) {
            for node in nodes {
                out.append(node)
                walk(node.children)
            }
        }
        walk(roots)
        return out
    }
}

/// The decoded shape of a Jamendo `tracks` response. Only the fields this
/// feature reads are decoded (the API returns a lot more, including a large
/// waveform blob). Verified against the v3.0 docs sample.
public struct JamendoEnvelope: Codable, Equatable, Sendable {
    public struct Headers: Codable, Equatable, Sendable {
        public let status: String
        public let code: Int
        public let errorMessage: String
        public let resultsCount: Int?
        public let resultsFullcount: Int?

        enum CodingKeys: String, CodingKey {
            case status, code
            case errorMessage = "error_message"
            case resultsCount = "results_count"
            case resultsFullcount = "results_fullcount"
        }
    }

    public let headers: Headers
    public let results: [JamendoTrack]
}

public struct JamendoTrack: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let duration: Int?
    public let artistID: String?
    public let artistName: String?
    public let albumName: String?
    public let albumID: String?
    public let licenseCcurl: String?
    public let audio: String?
    public let audiodownload: String?
    public let audiodownloadAllowed: Bool?
    public let albumImage: String?
    public let musicinfo: MusicInfo?

    public struct MusicInfo: Codable, Equatable, Hashable, Sendable {
        public let tags: Tags?
        public struct Tags: Codable, Equatable, Hashable, Sendable {
            public let genres: [String]?
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, duration, audio, musicinfo
        case artistID = "artist_id"
        case artistName = "artist_name"
        case albumName = "album_name"
        case albumID = "album_id"
        case licenseCcurl = "license_ccurl"
        case audiodownload
        case audiodownloadAllowed = "audiodownload_allowed"
        case albumImage = "album_image"
    }
}

/// The Jamendo v3.0 read client. Constructed with an injected `URLSession` so
/// the tests run against **recorded fixtures** — no live network in CI
/// (decision 21, Appendix R).
public struct JamendoAPI: Sendable {
    public let clientID: String
    public let session: URLSession
    public let baseURL: URL

    public init(clientID: String,
                session: URLSession = .shared,
                baseURL: URL = URL(string: "https://api.jamendo.com/v3.0")!) {
        self.clientID = clientID
        self.session = session
        self.baseURL = baseURL
    }

    /// The max `limit` the API accepts for a single page.
    public static let maxPageLimit = 200

    public struct Page: Sendable {
        public let tracks: [JamendoTrack]
        /// The absolute number of matching rows, from `fullcount=true`.
        public let totalCount: Int?
    }

    /// Fetch one page of a genre's tracks, **ordered popularity-descending**
    /// (§18A.3). `include=musicinfo` so the per-track genre tags decode;
    /// `audioformat=mp32` + `audiodlformat=mp32` for good-quality streams and
    /// downloads.
    public func tracks(tag: String, offset: Int, limit: Int) async throws -> Page {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw JamendoGenreError.notConfigured }
        guard !trimmed.isEmpty else { throw JamendoGenreError.catalogue("missing genre tag") }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("tracks"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "tags", value: trimmed),
            URLQueryItem(name: "order", value: "popularity_total"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "fullcount", value: "true"),
            URLQueryItem(name: "include", value: "musicinfo"),
            URLQueryItem(name: "audioformat", value: "mp32"),
            URLQueryItem(name: "audiodlformat", value: "mp32"),
        ]
        guard let url = components?.url else { throw JamendoGenreError.transport }

        let (data, response) = try await session.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw JamendoGenreError.transport
        }
        let envelope = try JSONDecoder().decode(JamendoEnvelope.self, from: data)
        guard envelope.headers.code == 0, envelope.headers.status == "success" else {
            throw JamendoGenreError.catalogue(envelope.headers.errorMessage)
        }
        return Page(tracks: envelope.results, totalCount: envelope.headers.resultsFullcount)
    }
}

/// The genre-library connector — a normal `RemoteLibraryProvider`, registered
/// in `RemoteConnectorCatalog`, **free tier** (FR-LIB-7). A subscribed genre is
/// an ordinary remote library: browse returns the popularity-ordered track
/// list, resolve hands back the stream URL, and caching / FR-LIB-8 / analysis /
/// decks all work through the existing pipeline (§18A.4).
public struct JamendoGenreProvider: RemoteLibraryProvider {
    public let api: JamendoAPI
    /// The genre path this provider serves (`electronic/techno`), from the
    /// source's `iaIdentifier`. Empty browse paths (the source detail's first
    /// load) fall back to it (§18A.3).
    public let genrePath: String?

    public var sourceKind: SourceKind { .jamendoGenre }

    public init(clientID: String, session: URLSession = .shared, sourcePath: String? = nil) {
        self.api = JamendoAPI(clientID: clientID, session: session)
        self.genrePath = sourcePath
    }

    public func browse(path: String) async throws -> [RemoteNode] {
        let page = try await api.tracks(tag: tag(from: path), offset: 0,
                                        limit: JamendoAPI.maxPageLimit)
        return page.tracks.map { track in
            RemoteNode(
                id: track.id,
                title: track.name,
                path: track.audio ?? "",
                kind: .audio,
                durationSec: track.duration.map(Double.init),
                metadata: RemoteTrackMetadata(
                    title: track.name,
                    artist: track.artistName,
                    album: track.albumName,
                    durationSec: track.duration.map(Double.init),
                    genre: track.musicinfo?.tags?.genres?.first,
                    artwork: RemoteArtwork(
                        id: track.albumID,
                        url: track.albumImage.flatMap(URL.init(string:)))
                )
            )
        }
    }

    public func resolve(node: RemoteNode) async throws -> ResolvedAsset {
        guard let url = URL(string: node.path), url.scheme != nil else {
            throw URLError(.badURL)
        }
        return ResolvedAsset(url: url, headers: [:], supportsByteRanges: true,
                             sizeBytes: node.sizeBytes)
    }

    public func refresh() async throws {}

    /// The absolute catalogue size for a genre (`fullcount`), backing the
    /// picker's "about N tracks" line — and the honest reachability check:
    /// an unreachable catalogue throws instead of reporting an empty library
    /// (§18A.6).
    public func catalogueCount(path: String) async throws -> Int {
        let page = try await api.tracks(tag: tag(from: path), offset: 0, limit: 1)
        return page.totalCount ?? page.tracks.count
    }

    /// The tag is always the last path component: `electronic/techno` filters
    /// the catalogue by `techno`, a distinct library from `electronic` (§18A.3).
    public func tag(from path: String) -> String {
        let effective = path.isEmpty ? (genrePath ?? "") : path
        return String(effective.split(separator: "/").last ?? Substring(effective))
    }
}
