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
            return String(localized: "Jamendo isn't configured in this build yet.", bundle: .module)
        case .transport:
            return String(localized: "Couldn't reach the Jamendo catalogue.", bundle: .module)
        case .catalogue(let message):
            return "The Jamendo catalogue returned an error: \(message)"
        }
    }
}

public enum JamendoImportPolicy {
    public static let sourceIdentifier = "catalog-search"
    public static let sourceTitle = "Jamendo Search"
    public static let explanation = "Search and import music from Jamendo and we will index it and add it to your collection."
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
/// tracks. The prior five "dead" tags were a spelling problem, not a
/// content problem: Jamendo's real tag values have no hyphens
/// ("nujazz"/"postrock"/"dreampop"/"musiqueconcrete", not "nu-jazz" etc.) —
/// four of five now resolve correctly under their real spelling; only
/// "boom-bap" never appeared anywhere in the sampled data or under any
/// spelling tried, and has been dropped rather than kept as a dead entry.
public enum JamendoGenreTree {
    public static let roots: [JamendoGenreNode] = [
        .init(name: String(localized: "Blues", bundle: .module), path: "blues", children: [
        ]),
        .init(name: String(localized: "Classical", bundle: .module), path: "classical", children: [
            .init(name: String(localized: "Baroque", bundle: .module), path: "classical/baroque"),
            .init(name: String(localized: "Choral", bundle: .module), path: "classical/choral"),
            .init(name: String(localized: "Contemporary Piano", bundle: .module), path: "classical/contemporarypiano"),
            .init(name: String(localized: "Medieval", bundle: .module), path: "classical/medieval"),
            .init(name: String(localized: "Neoclassical", bundle: .module), path: "classical/neoclassical"),
            .init(name: String(localized: "Ragtime", bundle: .module), path: "classical/ragtime"),
            .init(name: String(localized: "Symphonic", bundle: .module), path: "classical/symphonic"),
            .init(name: String(localized: "Waltz", bundle: .module), path: "classical/waltz"),
        ]),
        .init(name: String(localized: "Easy Listening", bundle: .module), path: "easylistening", children: [
            .init(name: String(localized: "Cabaret", bundle: .module), path: "easylistening/cabaret"),
            .init(name: String(localized: "Christian", bundle: .module), path: "easylistening/christian"),
            .init(name: String(localized: "Corporate", bundle: .module), path: "easylistening/corporate"),
            .init(name: String(localized: "Film Score", bundle: .module), path: "easylistening/filmscore"),
            .init(name: String(localized: "Intro", bundle: .module), path: "easylistening/intro"),
            .init(name: String(localized: "Jingle", bundle: .module), path: "easylistening/jingle"),
            .init(name: String(localized: "Kids / Quirky", bundle: .module), path: "easylistening/kidsquirky"),
            .init(name: String(localized: "Music Bed", bundle: .module), path: "easylistening/musicbed"),
            .init(name: String(localized: "Production", bundle: .module), path: "easylistening/production"),
            .init(name: String(localized: "Spoken Word", bundle: .module), path: "easylistening/spokenword"),
            .init(name: String(localized: "Trailer", bundle: .module), path: "easylistening/trailer"),
        ]),
        .init(name: String(localized: "Electronic", bundle: .module), path: "electronic", children: [
            .init(name: String(localized: "8-Bit", bundle: .module), path: "electronic/8bit"),
            .init(name: String(localized: "Acid House", bundle: .module), path: "electronic/acidhouse"),
            .init(name: String(localized: "Ambient", bundle: .module), path: "electronic/ambient"),
            .init(name: String(localized: "Breakbeat", bundle: .module), path: "electronic/breakbeat"),
            .init(name: String(localized: "Chillout", bundle: .module), path: "electronic/chillout"),
            .init(name: String(localized: "Chillwave", bundle: .module), path: "electronic/chillwave"),
            .init(name: String(localized: "Coldwave", bundle: .module), path: "electronic/coldwave"),
            .init(name: String(localized: "Dance", bundle: .module), path: "electronic/dance"),
            .init(name: String(localized: "Dark Ambient", bundle: .module), path: "electronic/darkambient"),
            .init(name: String(localized: "Darkwave", bundle: .module), path: "electronic/darkwave"),
            .init(name: String(localized: "Deep House", bundle: .module), path: "electronic/deephouse"),
            .init(name: String(localized: "Downtempo", bundle: .module), path: "electronic/downtempo"),
            .init(name: String(localized: "Drum & Bass", bundle: .module), path: "electronic/drumnbass"),
            .init(name: String(localized: "Dub", bundle: .module), path: "electronic/dub"),
            .init(name: String(localized: "Dubstep", bundle: .module), path: "electronic/dubstep"),
            .init(name: String(localized: "EDM", bundle: .module), path: "electronic/edm"),
            .init(name: String(localized: "Electrofunk", bundle: .module), path: "electronic/electrofunk"),
            .init(name: String(localized: "Electronica", bundle: .module), path: "electronic/electronica"),
            .init(name: String(localized: "Electropop", bundle: .module), path: "electronic/electropop"),
            .init(name: String(localized: "Electroswing", bundle: .module), path: "electronic/electroswing"),
            .init(name: String(localized: "Eurodance", bundle: .module), path: "electronic/eurodance"),
            .init(name: String(localized: "Glitch", bundle: .module), path: "electronic/glitch"),
            .init(name: String(localized: "House", bundle: .module), path: "electronic/house"),
            .init(name: String(localized: "IDM", bundle: .module), path: "electronic/idm"),
            .init(name: String(localized: "Industrial", bundle: .module), path: "electronic/industrial"),
            .init(name: String(localized: "New Age", bundle: .module), path: "electronic/newage"),
            .init(name: String(localized: "Progressive House", bundle: .module), path: "electronic/progressivehouse"),
            .init(name: String(localized: "Psytrance", bundle: .module), path: "electronic/psytrance"),
            .init(name: String(localized: "Synth Pop", bundle: .module), path: "electronic/synthpop"),
            .init(name: String(localized: "Synthwave", bundle: .module), path: "electronic/synthwave"),
            .init(name: String(localized: "Techno", bundle: .module), path: "electronic/techno"),
            .init(name: String(localized: "Trance", bundle: .module), path: "electronic/trance"),
            .init(name: String(localized: "Trip-Hop", bundle: .module), path: "electronic/triphop"),
            .init(name: String(localized: "Tropical House", bundle: .module), path: "electronic/tropicalhouse"),
        ]),
        .init(name: String(localized: "Experimental", bundle: .module), path: "experimental", children: [
            .init(name: String(localized: "Avant-Garde", bundle: .module), path: "experimental/avantgarde"),
            .init(name: String(localized: "Drone", bundle: .module), path: "experimental/drone"),
            .init(name: String(localized: "Musique Concrète", bundle: .module), path: "experimental/musiqueconcrete"),
        ]),
        .init(name: String(localized: "Folk · Country", bundle: .module), path: "folk", children: [
            .init(name: String(localized: "Americana", bundle: .module), path: "folk/americana"),
            .init(name: String(localized: "Bluegrass", bundle: .module), path: "folk/bluegrass"),
            .init(name: String(localized: "Celtic", bundle: .module), path: "folk/celtic"),
            .init(name: String(localized: "Chanson Française", bundle: .module), path: "folk/chansonfrancaise"),
            .init(name: String(localized: "Country", bundle: .module), path: "folk/country"),
            .init(name: String(localized: "Gypsy", bundle: .module), path: "folk/gypsy"),
            .init(name: String(localized: "Gypsy Jazz (Manouche)", bundle: .module), path: "folk/manouche"),
            .init(name: String(localized: "Singer-Songwriter", bundle: .module), path: "folk/singersongwriter"),
        ]),
        .init(name: String(localized: "Hip-Hop", bundle: .module), path: "hiphop", children: [
            .init(name: String(localized: "Chillhop", bundle: .module), path: "hiphop/chillhop"),
            .init(name: String(localized: "Lo-Fi", bundle: .module), path: "hiphop/lofi"),
            .init(name: String(localized: "Rap", bundle: .module), path: "hiphop/rap"),
            .init(name: String(localized: "Trap", bundle: .module), path: "hiphop/trap"),
        ]),
        .init(name: String(localized: "Jazz", bundle: .module), path: "jazz", children: [
            .init(name: String(localized: "Acid Jazz", bundle: .module), path: "jazz/acidjazz"),
            .init(name: String(localized: "Bebop", bundle: .module), path: "jazz/bebop"),
            .init(name: String(localized: "Free Jazz", bundle: .module), path: "jazz/freejazz"),
            .init(name: String(localized: "Jazz Fusion", bundle: .module), path: "jazz/jazzfusion"),
            .init(name: String(localized: "Jazz-Funk", bundle: .module), path: "jazz/jazzfunk"),
            .init(name: String(localized: "Latin Jazz", bundle: .module), path: "jazz/latinjazz"),
            .init(name: String(localized: "Nu-Jazz", bundle: .module), path: "jazz/nujazz"),
            .init(name: String(localized: "Smooth Jazz", bundle: .module), path: "jazz/smoothjazz"),
            .init(name: String(localized: "Swing", bundle: .module), path: "jazz/swing"),
        ]),
        .init(name: String(localized: "Metal", bundle: .module), path: "metal", children: [
            .init(name: String(localized: "Death Metal", bundle: .module), path: "metal/deathmetal"),
            .init(name: String(localized: "Heavy Metal", bundle: .module), path: "metal/heavymetal"),
            .init(name: String(localized: "Industrial Metal", bundle: .module), path: "metal/industrialmetal"),
            .init(name: String(localized: "Power Metal", bundle: .module), path: "metal/powermetal"),
            .init(name: String(localized: "Progressive Metal", bundle: .module), path: "metal/progressivemetal"),
            .init(name: String(localized: "Thrash Metal", bundle: .module), path: "metal/thrashmetal"),
        ]),
        .init(name: String(localized: "Pop", bundle: .module), path: "pop", children: [
            .init(name: String(localized: "Adult Contemporary", bundle: .module), path: "pop/adultcontemporary"),
            .init(name: String(localized: "Alternative Pop", bundle: .module), path: "pop/alternativepop"),
            .init(name: String(localized: "Britpop", bundle: .module), path: "pop/britpop"),
            .init(name: String(localized: "Dance Pop", bundle: .module), path: "pop/dancepop"),
            .init(name: String(localized: "Dream Pop", bundle: .module), path: "pop/dreampop"),
            .init(name: String(localized: "French Pop", bundle: .module), path: "pop/frenchpop"),
            .init(name: String(localized: "Indie Pop", bundle: .module), path: "pop/indiepop"),
        ]),
        .init(name: String(localized: "Rock", bundle: .module), path: "rock", children: [
            .init(name: String(localized: "Alternative Rock", bundle: .module), path: "rock/alternativerock"),
            .init(name: String(localized: "Art Rock", bundle: .module), path: "rock/artrock"),
            .init(name: String(localized: "Blues Rock", bundle: .module), path: "rock/bluesrock"),
            .init(name: String(localized: "Classic Rock", bundle: .module), path: "rock/classicrock"),
            .init(name: String(localized: "Electro Rock", bundle: .module), path: "rock/electrorock"),
            .init(name: String(localized: "Emo", bundle: .module), path: "rock/emo"),
            .init(name: String(localized: "Garage", bundle: .module), path: "rock/garage"),
            .init(name: String(localized: "Gothic", bundle: .module), path: "rock/gothic"),
            .init(name: String(localized: "Grindcore", bundle: .module), path: "rock/grindcore"),
            .init(name: String(localized: "Grunge", bundle: .module), path: "rock/grunge"),
            .init(name: String(localized: "Hardcore", bundle: .module), path: "rock/hardcore"),
            .init(name: String(localized: "Hardcore Punk", bundle: .module), path: "rock/hardcorepunk"),
            .init(name: String(localized: "Indie", bundle: .module), path: "rock/indie"),
            .init(name: String(localized: "Indie Rock", bundle: .module), path: "rock/indierock"),
            .init(name: String(localized: "Industrial Rock", bundle: .module), path: "rock/industrialrock"),
            .init(name: String(localized: "New Wave", bundle: .module), path: "rock/newwave"),
            .init(name: String(localized: "Pop Punk", bundle: .module), path: "rock/poppunk"),
            .init(name: String(localized: "Pop Rock", bundle: .module), path: "rock/poprock"),
            .init(name: String(localized: "Post-Punk", bundle: .module), path: "rock/postpunk"),
            .init(name: String(localized: "Post-Rock", bundle: .module), path: "rock/postrock"),
            .init(name: String(localized: "Progressive Rock", bundle: .module), path: "rock/progressiverock"),
            .init(name: String(localized: "Psychedelic Rock", bundle: .module), path: "rock/psychedelicrock"),
            .init(name: String(localized: "Punk", bundle: .module), path: "rock/punk"),
            .init(name: String(localized: "Rock & Roll", bundle: .module), path: "rock/rocknroll"),
            .init(name: String(localized: "Rockabilly", bundle: .module), path: "rock/rockabilly"),
            .init(name: String(localized: "Shoegaze", bundle: .module), path: "rock/shoegaze"),
            .init(name: String(localized: "Southern Rock", bundle: .module), path: "rock/southernrock"),
            .init(name: String(localized: "Surf Rock", bundle: .module), path: "rock/surfrock"),
        ]),
        .init(name: String(localized: "Soul · Funk · R&B", bundle: .module), path: "soul", children: [
            .init(name: String(localized: "Alternative R&B", bundle: .module), path: "soul/alternativernb"),
            .init(name: String(localized: "Disco", bundle: .module), path: "soul/disco"),
            .init(name: String(localized: "Funk", bundle: .module), path: "soul/funk"),
            .init(name: String(localized: "Gospel", bundle: .module), path: "soul/gospel"),
            .init(name: String(localized: "R&B", bundle: .module), path: "soul/rnb"),
        ]),
        .init(name: String(localized: "World", bundle: .module), path: "world", children: [
            .init(name: String(localized: "African", bundle: .module), path: "world/african"),
            .init(name: String(localized: "Afrobeat", bundle: .module), path: "world/afrobeat"),
            .init(name: String(localized: "Balkan", bundle: .module), path: "world/balkan"),
            .init(name: String(localized: "Bossa Nova", bundle: .module), path: "world/bossanova"),
            .init(name: String(localized: "Dancehall", bundle: .module), path: "world/dancehall"),
            .init(name: String(localized: "Flamenco", bundle: .module), path: "world/flamenco"),
            .init(name: String(localized: "Indian", bundle: .module), path: "world/indian"),
            .init(name: String(localized: "Latin", bundle: .module), path: "world/latin"),
            .init(name: String(localized: "Merengue", bundle: .module), path: "world/merengue"),
            .init(name: String(localized: "Middle Eastern", bundle: .module), path: "world/middleeastern"),
            .init(name: String(localized: "Oriental", bundle: .module), path: "world/oriental"),
            .init(name: String(localized: "Ragga", bundle: .module), path: "world/ragga"),
            .init(name: String(localized: "Reggae", bundle: .module), path: "world/reggae"),
            .init(name: String(localized: "Reggaeton", bundle: .module), path: "world/reggaeton"),
            .init(name: String(localized: "Rumba", bundle: .module), path: "world/rumba"),
            .init(name: String(localized: "Samba", bundle: .module), path: "world/samba"),
            .init(name: String(localized: "Ska", bundle: .module), path: "world/ska"),
            .init(name: String(localized: "Tribal", bundle: .module), path: "world/tribal"),
            .init(name: String(localized: "Zouk", bundle: .module), path: "world/zouk"),
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
