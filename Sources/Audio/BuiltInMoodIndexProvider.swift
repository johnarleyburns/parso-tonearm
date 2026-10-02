import Foundation

/// One track of the bundled Jamendo/archive.org mood-starter index
/// (docs/plans/builtin-mood-starter-index-plan.md, expansion phase): real
/// CC-licensed tracks whose metadata AND precomputed CLAP embedding ship in
/// the app bundle, but whose audio streams from the original host
/// (Jamendo/archive.org) only when the user actually plays one — no bundled
/// audio, no background network fetch for search/indexing.
public struct BuiltInMoodTrack: Codable, Sendable {
    public let id: String
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

    public var hasMusicalAnalysis: Bool { bpm != nil && key != nil }

    public init(id: String, title: String, artist: String, genre: String, license: String,
                licenseURL: String?, durationSec: Double, streamURL: String, artworkURL: String?,
                dimensions: Int, scale: Double, quantizedVector: Data, bpm: Double?, key: String?,
                energy: Double?, analysisScopeSeconds: Double?) {
        self.id = id
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
    }

    /// The legacy JSON index (now only BuiltInAnalyzer's source) keeps the embedding as base64.
    enum CodingKeys: String, CodingKey {
        case id, title, artist, genre, license, licenseURL, durationSec, streamURL, artworkURL
        case dimensions, scale, bpm, key, energy, analysisScopeSeconds
        case quantizedVector = "quantizedVectorBase64"
    }
}

/// The bundled Mood Starter tracks, read from the starter DB (`StarterLibrary`).
public enum BuiltInMoodIndexProvider {
    public static var tracks: [BuiltInMoodTrack] {
        (try? StarterLibrary.shared?.tracks()) ?? []
    }
}
