import Foundation
import GRDB

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

    public static func key(pack: StarterBlendPack, trackID: String) -> String { "\(pack.releaseTag):\(trackID)" }

    public var trackID: String { String(catalogKey.split(separator: ":", maxSplits: 1).last ?? "") }

    /// Genre, subgenre and key, when the required ones are stored and valid.
    public var traits: BlendTraits? {
        guard let genre, let camelotKey else { return nil }
        let value = BlendTraits(genre: genre, subgenre: subgenre, camelotKey: camelotKey)
        return value.isValid ? value : nil
    }

    /// Whether a new or Keep Playing edge may use this row: eligible state and every fact valid.
    public var isSelectable: Bool {
        state >= .blendEligible && (facts?.isBlendReady ?? false) && traits != nil
    }

    /// The explicit source for this row: only a mirrored Starter asset of `pack` whose stored
    /// `sourceURL` is that asset. Nil for unmirrored/synthetic IDs or a row without a stored source.
    public func resolvedLocator(in pack: StarterBlendPack) -> AudioLocator? {
        guard packTag == pack.releaseTag, let sourceURL, let url = URL(string: sourceURL),
              pack.assetURL(trackID: trackID) == url else { return nil }
        return pack.locator(trackID: trackID)
    }

    /// Whether Keep Playing may append this row: eligible state, complete planner facts, valid
    /// genre and Camelot key, and a resolvable source. Never consults a model or the network.
    public func isKeepPlayingCandidate(in pack: StarterBlendPack) -> Bool {
        isSelectable && resolvedLocator(in: pack) != nil
    }

    /// The stored facts, when complete.
    public var facts: StarterTrackFacts? {
        guard let durationSeconds, let bpm, let beatPeriod, let beatPhase, let rmsDB else { return nil }
        return StarterTrackFacts(id: trackID, durationSeconds: durationSeconds, bpm: bpm, beatPeriod: beatPeriod,
                                 beatPhase: beatPhase, rmsDB: rmsDB)
    }
}

/// A concrete edge plan stored with the catalog (supplied by a pack, or derived from catalog facts).
public struct BlendCatalogEdge: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "blend_catalog_edge"
    public var fromKey: String
    public var toKey: String
    public var packTag: String
    public var planJSON: Data

    public var plan: BlendEdgePlan? { try? JSONDecoder().decode(BlendEdgePlan.self, from: planJSON) }
}
