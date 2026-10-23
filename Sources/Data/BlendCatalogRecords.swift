import Foundation
import GRDB

/// Which kind of source a catalog row plays from.
public enum BlendCatalogSourceKind: String, Codable, Sendable, Equatable {
    /// An immutable asset on the pinned Starter Release (the 36 mirrored IDs only).
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

    /// The explicit source of this row. A Starter row yields only the pinned Release asset of one of the
    /// 36 mirrored IDs; a Jamendo row yields provider identity plus its cached URL. A Release locator is
    /// never produced for a non-starter ID, and a Jamendo locator never for a Starter ID.
    public func audioLocator(in pack: StarterBlendPack = .v1) -> AudioLocator? {
        switch sourceKind {
        case .starterRelease?:
            guard packTag == pack.releaseTag else { return nil }
            return pack.locator(trackID: trackID)
        case .jamendo?:
            guard let id = providerTrackID, !id.isEmpty, !pack.contains(trackID: id),
                  !pack.contains(trackID: trackID) else { return nil }
            let url = cachedURL.flatMap(URL.init(string:)).flatMap { pack.owns($0) ? nil : $0 }
            return .jamendo(trackID: id, cachedURL: url, expiry: cachedURLExpiry)
        case nil:
            return nil
        }
    }

    /// Catalog key of a session track ID: the 36 mirrored Starter IDs live under the pack tag, every
    /// other ID is an ordinary Jamendo catalog row.
    public static func catalogKey(forTrackID id: String, pack: StarterBlendPack) -> String {
        pack.contains(trackID: id) ? key(pack: pack, trackID: id) : jamendoKey(trackID: id)
    }

    /// Source-aware Keep Playing admission: eligible state, complete planner facts, canonical genre and
    /// valid Camelot key (all persisted), and a real `AudioLocator` - a verified mirrored asset for a
    /// Starter ID, or a Jamendo provider identity whose numeric ID matches the row for any other.
    /// Never consults a model, the network, or a GitHub URL for a Jamendo row.
    public func keepPlayingLocator(in pack: StarterBlendPack) -> AudioLocator? {
        guard isSelectable, let locator = audioLocator(in: pack) else { return nil }
        switch locator {
        case .starterRelease:
            return packTag == pack.releaseTag && catalogKey == Self.key(pack: pack, trackID: trackID) ? locator : nil
        case .jamendo(let id, _, _):
            guard packTag == Self.jamendoPackTag, catalogKey == Self.jamendoKey(trackID: id),
                  Int64(id) != nil else { return nil }
            return locator
        }
    }

    public func isKeepPlayingCandidate(in pack: StarterBlendPack) -> Bool {
        keepPlayingLocator(in: pack) != nil
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
