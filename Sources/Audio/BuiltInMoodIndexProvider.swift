import Foundation

/// One track of the bundled Jamendo/archive.org mood-starter index
/// (docs/plans/builtin-mood-starter-index-plan.md, expansion phase): real
/// CC-licensed tracks whose metadata AND precomputed CLAP embedding ship in
/// the app bundle, but whose audio streams from the original host
/// (Jamendo/archive.org) only when the user actually plays one — no bundled
/// audio, no background network fetch for search/indexing.
public struct BuiltInMoodTrack: Codable, Sendable {
    public let id: String
    /// Stable upstream catalog identity — never a stream URL, which is mutable metadata. Jamendo
    /// rows use provider `"jamendo"` and Jamendo's own canonical track id. This, not `streamURL`,
    /// is the merge key `LibraryStore.mergeStarterLibrary` matches existing rows against.
    public let provider: String
    public let providerTrackID: String
    /// `EmbeddingSpace.current.fingerprint` at the time this row's embedding was computed — every
    /// starter read/write/merge validates this against the installed space (`StarterEmbeddingContract`)
    /// before trusting `quantizedVector`.
    public let embeddingSpaceFingerprint: String
    public let title: String
    public let artist: String
    public let genre: String
    public let license: String
    public let licenseURL: String?
    public let durationSec: Double
    public let streamURL: String
    /// Jamendo's own `album_image` (a public CDN URL) when the source provides one; nil for the
    /// archive.org classical items.
    public let artworkURL: String?
    public let dimensions: Int
    public let scale: Double
    /// The int8 CLAP embedding (`dimensions` bytes).
    public let quantizedVector: Data
    /// Tempo, Camelot key and energy from the same mid-track window the on-device indexer uses.
    /// Build a Mix needs BPM + key to place a track. Absent for the few tracks whose audio couldn't
    /// be analysed.
    public let bpm: Double?
    public let key: String?
    public let energy: Double?
    public let analysisScopeSeconds: Double?
    /// Compact beat/phrase/loudness descriptor for blend-transition planning; nil when not yet
    /// computed for this track (musical analysis alone does not require it).
    public let transitionProfile: TransitionProfile?

    public var hasMusicalAnalysis: Bool { bpm != nil && key != nil }

    public init(id: String, provider: String, providerTrackID: String, embeddingSpaceFingerprint: String,
                title: String, artist: String, genre: String, license: String,
                licenseURL: String?, durationSec: Double, streamURL: String, artworkURL: String?,
                dimensions: Int, scale: Double, quantizedVector: Data, bpm: Double?, key: String?,
                energy: Double?, analysisScopeSeconds: Double?, transitionProfile: TransitionProfile?) {
        self.id = id
        self.provider = provider
        self.providerTrackID = providerTrackID
        self.embeddingSpaceFingerprint = embeddingSpaceFingerprint
        self.title = title
        self.artist = artist
        self.genre = genre
        self.license = license
        self.licenseURL = licenseURL
        self.durationSec = durationSec
        self.streamURL = streamURL
        self.artworkURL = artworkURL
        self.dimensions = dimensions
        self.scale = scale
        self.quantizedVector = quantizedVector
        self.bpm = bpm
        self.key = key
        self.energy = energy
        self.analysisScopeSeconds = analysisScopeSeconds
        self.transitionProfile = transitionProfile
    }

    /// The legacy JSON index (now only BuiltInAnalyzer's source) keeps the embedding as base64.
    enum CodingKeys: String, CodingKey {
        case id, provider, providerTrackID, embeddingSpaceFingerprint
        case title, artist, genre, license, licenseURL, durationSec, streamURL, artworkURL
        case dimensions, scale, bpm, key, energy, analysisScopeSeconds, transitionProfile
        case quantizedVector = "quantizedVectorBase64"
    }
}

/// The bundled Mood Starter tracks, read from the starter DB (`StarterLibrary`).
public enum BuiltInMoodIndexProvider {
    /// `expecting` is the installed embedding space (`EmbeddingSpace.current.starterContract` at
    /// every real call site) — a bundled starter DB whose rows don't match it (wrong model/
    /// projection generation) is treated the same as having no starter DB at all, never partially
    /// trusted.
    public static func tracks(expecting contract: StarterEmbeddingContract) -> [BuiltInMoodTrack] {
        (try? StarterLibrary.shared?.tracks(expecting: contract)) ?? []
    }
}
