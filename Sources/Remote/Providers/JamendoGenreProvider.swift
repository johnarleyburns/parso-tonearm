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
    /// The application `client_id`. In a normal build it comes from the app's
    /// Info.plist; an empty value is the honest "not configured" state
    /// (§18A.6). Under `-uiRegression` a `-jamendoClientID <id>` launch
    /// argument supplies it (the live lane's credential, from `.test-credentials`);
    /// absent that, the canned `jamendo-mock` accepts a placeholder — it ignores
    /// whatever is passed, and the gate must not make the deterministic lane
    /// unavailable.
    public static var clientID: String {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiRegression") {
            if let index = arguments.firstIndex(of: "-jamendoClientID"),
               arguments.indices.contains(index + 1),
               !arguments[index + 1].isEmpty {
                return arguments[index + 1]
            }
            return "ui-regression"
        }
        // A user-supplied key wins over the app's (plan 6.3 decision 2): it is
        // their own rate limit, and it keeps the feature working if ours is
        // ever pulled.
        return JamendoCredentialStore(appClientID: { bundledClientID })
            .resolved()?.clientID ?? ""
    }

    /// The app's own key as shipped — Info.plist, filled from the untracked
    /// `Config/Secrets.xcconfig` locally and a CI secret for TestFlight. Empty
    /// is the honest not-configured state (§18A.6), never a fabricated key.
    public static var bundledClientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "JamendoClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// The catalogue base URL. The `-jamendoBaseURL <url>` launch argument
    /// overrides it **only** under `-uiRegression` (dj-regression-suite hook
    /// 5.6) so the canned `jamendo-mock` can stand in for the live API. In a
    /// normal build the override is never honoured.
    public static var baseURL: URL {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiRegression"),
           let index = arguments.firstIndex(of: "-jamendoBaseURL"),
           arguments.indices.contains(index + 1),
           let override = URL(string: arguments[index + 1]),
           override.scheme != nil {
            return override
        }
        return URL(string: "https://api.jamendo.com/v3.0")!
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
/// Jamendo exposes no taxonomy endpoint, so the tree is built here from real,
/// evidence-based tags — not invented names. Real report: "the Jamendo
/// onboarding genres are much too sparse... essentially exposing every genre
/// category that jamendo has." The previous 8-top-level/33-node tree was
/// replaced (2026-09) after aggregating `musicinfo.tags.genres` across ~7,800
/// real tracks sampled live from the API, then verifying every candidate tag
/// via a live `tags=` search (retried — Jamendo's search endpoint is known to
/// intermittently return zero results for a real tag under repeat identical
/// queries, already documented on `JamendoAPI.tracks(tag:offset:limit:)`'s own
/// retry). Every path below is a tag confirmed to return real, CC-licensed
/// tracks. The prior TODO's five "dead" tags were a spelling problem, not a
/// content problem: Jamendo's real tag values have no hyphens
/// ("nujazz"/"postrock"/"dreampop"/"musiqueconcrete", not "nu-jazz" etc.) —
/// four of five now resolve correctly under their real spelling; only
/// "boom-bap" never appeared anywhere in the sampled data or under any
/// spelling tried, and has been dropped rather than kept as a dead entry.
public enum JamendoGenreTree {
    public static let roots: [JamendoGenreNode] = [
        .init(name: "Blues", path: "blues", children: [
        ]),
        .init(name: "Classical", path: "classical", children: [
            .init(name: "Baroque", path: "classical/baroque"),
            .init(name: "Choral", path: "classical/choral"),
            .init(name: "Contemporary Piano", path: "classical/contemporarypiano"),
            .init(name: "Medieval", path: "classical/medieval"),
            .init(name: "Neoclassical", path: "classical/neoclassical"),
            .init(name: "Ragtime", path: "classical/ragtime"),
            .init(name: "Symphonic", path: "classical/symphonic"),
            .init(name: "Waltz", path: "classical/waltz"),
        ]),
        .init(name: "Easy Listening", path: "easylistening", children: [
            .init(name: "Cabaret", path: "easylistening/cabaret"),
            .init(name: "Christian", path: "easylistening/christian"),
            .init(name: "Corporate", path: "easylistening/corporate"),
            .init(name: "Film Score", path: "easylistening/filmscore"),
            .init(name: "Intro", path: "easylistening/intro"),
            .init(name: "Jingle", path: "easylistening/jingle"),
            .init(name: "Kids / Quirky", path: "easylistening/kidsquirky"),
            .init(name: "Music Bed", path: "easylistening/musicbed"),
            .init(name: "Production", path: "easylistening/production"),
            .init(name: "Spoken Word", path: "easylistening/spokenword"),
            .init(name: "Trailer", path: "easylistening/trailer"),
        ]),
        .init(name: "Electronic", path: "electronic", children: [
            .init(name: "8-Bit", path: "electronic/8bit"),
            .init(name: "Acid House", path: "electronic/acidhouse"),
            .init(name: "Ambient", path: "electronic/ambient"),
            .init(name: "Breakbeat", path: "electronic/breakbeat"),
            .init(name: "Chillout", path: "electronic/chillout"),
            .init(name: "Chillwave", path: "electronic/chillwave"),
            .init(name: "Coldwave", path: "electronic/coldwave"),
            .init(name: "Dance", path: "electronic/dance"),
            .init(name: "Dark Ambient", path: "electronic/darkambient"),
            .init(name: "Darkwave", path: "electronic/darkwave"),
            .init(name: "Deep House", path: "electronic/deephouse"),
            .init(name: "Downtempo", path: "electronic/downtempo"),
            .init(name: "Drum & Bass", path: "electronic/drumnbass"),
            .init(name: "Dub", path: "electronic/dub"),
            .init(name: "Dubstep", path: "electronic/dubstep"),
            .init(name: "EDM", path: "electronic/edm"),
            .init(name: "Electrofunk", path: "electronic/electrofunk"),
            .init(name: "Electronica", path: "electronic/electronica"),
            .init(name: "Electropop", path: "electronic/electropop"),
            .init(name: "Electroswing", path: "electronic/electroswing"),
            .init(name: "Eurodance", path: "electronic/eurodance"),
            .init(name: "Glitch", path: "electronic/glitch"),
            .init(name: "House", path: "electronic/house"),
            .init(name: "IDM", path: "electronic/idm"),
            .init(name: "Industrial", path: "electronic/industrial"),
            .init(name: "New Age", path: "electronic/newage"),
            .init(name: "Progressive House", path: "electronic/progressivehouse"),
            .init(name: "Psytrance", path: "electronic/psytrance"),
            .init(name: "Synth Pop", path: "electronic/synthpop"),
            .init(name: "Synthwave", path: "electronic/synthwave"),
            .init(name: "Techno", path: "electronic/techno"),
            .init(name: "Trance", path: "electronic/trance"),
            .init(name: "Trip-Hop", path: "electronic/triphop"),
            .init(name: "Tropical House", path: "electronic/tropicalhouse"),
        ]),
        .init(name: "Experimental", path: "experimental", children: [
            .init(name: "Avant-Garde", path: "experimental/avantgarde"),
            .init(name: "Drone", path: "experimental/drone"),
            .init(name: "Musique Concrète", path: "experimental/musiqueconcrete"),
        ]),
        .init(name: "Folk · Country", path: "folk", children: [
            .init(name: "Americana", path: "folk/americana"),
            .init(name: "Bluegrass", path: "folk/bluegrass"),
            .init(name: "Celtic", path: "folk/celtic"),
            .init(name: "Chanson Française", path: "folk/chansonfrancaise"),
            .init(name: "Country", path: "folk/country"),
            .init(name: "Gypsy", path: "folk/gypsy"),
            .init(name: "Gypsy Jazz (Manouche)", path: "folk/manouche"),
            .init(name: "Singer-Songwriter", path: "folk/singersongwriter"),
        ]),
        .init(name: "Hip-Hop", path: "hiphop", children: [
            .init(name: "Chillhop", path: "hiphop/chillhop"),
            .init(name: "Lo-Fi", path: "hiphop/lofi"),
            .init(name: "Rap", path: "hiphop/rap"),
            .init(name: "Trap", path: "hiphop/trap"),
        ]),
        .init(name: "Jazz", path: "jazz", children: [
            .init(name: "Acid Jazz", path: "jazz/acidjazz"),
            .init(name: "Bebop", path: "jazz/bebop"),
            .init(name: "Free Jazz", path: "jazz/freejazz"),
            .init(name: "Jazz Fusion", path: "jazz/jazzfusion"),
            .init(name: "Jazz-Funk", path: "jazz/jazzfunk"),
            .init(name: "Latin Jazz", path: "jazz/latinjazz"),
            .init(name: "Nu-Jazz", path: "jazz/nujazz"),
            .init(name: "Smooth Jazz", path: "jazz/smoothjazz"),
            .init(name: "Swing", path: "jazz/swing"),
        ]),
        .init(name: "Metal", path: "metal", children: [
            .init(name: "Death Metal", path: "metal/deathmetal"),
            .init(name: "Heavy Metal", path: "metal/heavymetal"),
            .init(name: "Industrial Metal", path: "metal/industrialmetal"),
            .init(name: "Power Metal", path: "metal/powermetal"),
            .init(name: "Progressive Metal", path: "metal/progressivemetal"),
            .init(name: "Thrash Metal", path: "metal/thrashmetal"),
        ]),
        .init(name: "Pop", path: "pop", children: [
            .init(name: "Adult Contemporary", path: "pop/adultcontemporary"),
            .init(name: "Alternative Pop", path: "pop/alternativepop"),
            .init(name: "Britpop", path: "pop/britpop"),
            .init(name: "Dance Pop", path: "pop/dancepop"),
            .init(name: "Dream Pop", path: "pop/dreampop"),
            .init(name: "French Pop", path: "pop/frenchpop"),
            .init(name: "Indie Pop", path: "pop/indiepop"),
        ]),
        .init(name: "Rock", path: "rock", children: [
            .init(name: "Alternative Rock", path: "rock/alternativerock"),
            .init(name: "Art Rock", path: "rock/artrock"),
            .init(name: "Blues Rock", path: "rock/bluesrock"),
            .init(name: "Classic Rock", path: "rock/classicrock"),
            .init(name: "Electro Rock", path: "rock/electrorock"),
            .init(name: "Emo", path: "rock/emo"),
            .init(name: "Garage", path: "rock/garage"),
            .init(name: "Gothic", path: "rock/gothic"),
            .init(name: "Grindcore", path: "rock/grindcore"),
            .init(name: "Grunge", path: "rock/grunge"),
            .init(name: "Hardcore", path: "rock/hardcore"),
            .init(name: "Hardcore Punk", path: "rock/hardcorepunk"),
            .init(name: "Indie", path: "rock/indie"),
            .init(name: "Indie Rock", path: "rock/indierock"),
            .init(name: "Industrial Rock", path: "rock/industrialrock"),
            .init(name: "New Wave", path: "rock/newwave"),
            .init(name: "Pop Punk", path: "rock/poppunk"),
            .init(name: "Pop Rock", path: "rock/poprock"),
            .init(name: "Post-Punk", path: "rock/postpunk"),
            .init(name: "Post-Rock", path: "rock/postrock"),
            .init(name: "Progressive Rock", path: "rock/progressiverock"),
            .init(name: "Psychedelic Rock", path: "rock/psychedelicrock"),
            .init(name: "Punk", path: "rock/punk"),
            .init(name: "Rock & Roll", path: "rock/rocknroll"),
            .init(name: "Rockabilly", path: "rock/rockabilly"),
            .init(name: "Shoegaze", path: "rock/shoegaze"),
            .init(name: "Southern Rock", path: "rock/southernrock"),
            .init(name: "Surf Rock", path: "rock/surfrock"),
        ]),
        .init(name: "Soul · Funk · R&B", path: "soul", children: [
            .init(name: "Alternative R&B", path: "soul/alternativernb"),
            .init(name: "Disco", path: "soul/disco"),
            .init(name: "Funk", path: "soul/funk"),
            .init(name: "Gospel", path: "soul/gospel"),
            .init(name: "R&B", path: "soul/rnb"),
        ]),
        .init(name: "World", path: "world", children: [
            .init(name: "African", path: "world/african"),
            .init(name: "Afrobeat", path: "world/afrobeat"),
            .init(name: "Balkan", path: "world/balkan"),
            .init(name: "Bossa Nova", path: "world/bossanova"),
            .init(name: "Dancehall", path: "world/dancehall"),
            .init(name: "Flamenco", path: "world/flamenco"),
            .init(name: "Indian", path: "world/indian"),
            .init(name: "Latin", path: "world/latin"),
            .init(name: "Merengue", path: "world/merengue"),
            .init(name: "Middle Eastern", path: "world/middleeastern"),
            .init(name: "Oriental", path: "world/oriental"),
            .init(name: "Ragga", path: "world/ragga"),
            .init(name: "Reggae", path: "world/reggae"),
            .init(name: "Reggaeton", path: "world/reggaeton"),
            .init(name: "Rumba", path: "world/rumba"),
            .init(name: "Samba", path: "world/samba"),
            .init(name: "Ska", path: "world/ska"),
            .init(name: "Tribal", path: "world/tribal"),
            .init(name: "Zouk", path: "world/zouk"),
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

        let page = try await fetchTracksPage(tag: trimmed, offset: offset, limit: limit)
        // Verified against the live endpoint: an identical `tracks?tags=…`
        // request intermittently answers a well-formed `status: success`
        // envelope with zero rows for a tag that, re-requested moments later
        // unchanged, returns thousands — a transient upstream flake (backend
        // replica or edge cache), not a genuinely empty genre. That is exactly
        // what makes a genre look broken to a user who only ever sees the
        // first page: the default genre and any single tap can land on the
        // empty answer. One retry, first page only (`offset == 0`) so a real
        // end-of-list page beyond it is never mistaken for this.
        guard page.tracks.isEmpty, offset == 0 else { return page }
        return try await fetchTracksPage(tag: trimmed, offset: offset, limit: limit)
    }

    private func fetchTracksPage(tag: String, offset: Int, limit: Int) async throws -> Page {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("tracks"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "tags", value: tag),
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

    /// Full-catalogue text search (`namesearch` matches track name, artist,
    /// and album — the closest single param to a general search box; verified
    /// against the v3.0 docs sample), not scoped to any genre tag.
    public func search(query: String, offset: Int, limit: Int) async throws -> Page {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw JamendoGenreError.notConfigured }
        guard !trimmed.isEmpty else { throw JamendoGenreError.catalogue("empty search query") }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("tracks"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "namesearch", value: trimmed),
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
        self.api = JamendoAPI(clientID: clientID, session: session,
                              baseURL: JamendoAppConfig.baseURL)
        self.genrePath = sourcePath
    }

    public func browse(path: String) async throws -> [RemoteNode] {
        let page = try await api.tracks(tag: tag(from: path), offset: 0,
                                        limit: JamendoAPI.maxPageLimit)
        return Self.nodes(from: page.tracks)
    }

    /// Shared `JamendoTrack` → `RemoteNode` mapping, used by both the
    /// persisted-library `browse(path:)` above and the ad-hoc Jamendo browse
    /// screen (genre paging + full-catalogue search), so both paths produce
    /// identically-shaped nodes.
    public static func nodes(from tracks: [JamendoTrack]) -> [RemoteNode] {
        tracks.map { track in
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
