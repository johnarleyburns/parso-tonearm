import Foundation
import GRDB

/// Which kind of source a catalog row plays from.
public enum BlendCatalogSourceKind: String, Codable, Sendable, Equatable {
    /// An immutable asset on the pinned Starter Release (the 54 mirrored IDs only).
    case starterRelease
    /// A Jamendo catalog track: provider `jamendo` plus a stable track ID.
    case jamendo
}

/// Persistent catalog row for one blendable track: its lifecycle state and every fact a blend needs.
/// `catalogKey` is `<pack release tag>:<track id>` for Starter assets.
public struct BlendCatalogTrack: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "blend_catalog_track"
    public var catalogKey: String
    public var packTag: String
    public var state: BlendCatalogState
    public var durationSeconds: Double?
    public var bpm: Double?
    public var beatPeriod: Double?
    public var beatPhase: Double?
    public var rmsDB: Double?
    public var updatedAt: Date
    /// Selection facts (v36). Nil for rows saved before they existed: such rows are never selectable.
    public var genre: String? = nil
    public var subgenre: String? = nil
    public var camelotKey: String? = nil
    public var sourceURL: String? = nil
    /// Provenance of the stored facts (e.g. `starter-blends-aac-v1`); nil when unknown.
    public var analysisVersion: String? = nil
    /// Immutable provider/catalog identity from `starter-v4.sqlite` (`jamendo-<id>`, v37). Distinct from
    /// `catalogKey` (local storage identity) and `packTag` (the Starter audio pack release).
    public var catalogID: String? = nil
    /// Durable audio source (v38). `sourceURL` above is legacy display data and is never identity.
    public var sourceKind: BlendCatalogSourceKind? = nil
    /// Stable Jamendo track ID for `.jamendo` rows.
    public var providerTrackID: String? = nil
    /// Refreshable Jamendo stream URL and optional expiry: cache data, never identity.
    public var cachedURL: String? = nil
    public var cachedURLExpiry: Date? = nil

    /// Pack tag of general (non-Starter) catalog rows.
    public static let jamendoPackTag = "jamendo"
    public static func jamendoKey(trackID: String) -> String { "\(jamendoPackTag):\(trackID)" }

    public var trackID: String { String(catalogKey.split(separator: ":", maxSplits: 1).last ?? "") }

    /// The explicit source of this row: Jamendo provider identity plus its cached URL. A legacy
    /// `.starterRelease` row (seeded before the curated-blend feature was removed) resolves the same
    /// way — the track is genuinely Jamendo-sourced, and the pinned Release mirror it used to read
    /// from no longer exists — falling back to `trackID` for identity since those rows were seeded
    /// with no `providerTrackID`.
    public func audioLocator() -> AudioLocator? {
        guard sourceKind != nil else { return nil }
        // nil (never stored) falls back to trackID for legacy rows; an explicit empty string is
        // corrupt data, not an absent value, and is rejected rather than silently falling back.
        let id: String
        if let providerTrackID {
            guard !providerTrackID.isEmpty else { return nil }
            id = providerTrackID
        } else {
            id = trackID
        }
        guard !id.isEmpty else { return nil }
        let url = cachedURL.flatMap(URL.init(string:))
        return .jamendo(trackID: id, cachedURL: url, expiry: cachedURLExpiry)
    }
}
