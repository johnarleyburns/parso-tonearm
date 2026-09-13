import Foundation
import GRDB

// MARK: - Auto-playlists (§14.3, plan M3 commit 3.3)
//
// Split out of `DJRecords.swift` — standalone record types, no cross-file
// access-level changes needed.

/// The user's brief as a first-class editable row (§14.3, FR-PLIST-7): the
/// prompt, the arc (kind + parameter payload), the target length, the
/// `.sortedKeys`-encoded `SequencingConstraints`, the seed track/crate, and the
/// seeded tie-break `randomSeed` that makes generation reproducible (NFR-DET-1).
public struct AutoPlaylistBrief: Codable, Identifiable, FetchableRecord,
                                 MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var prompt: String
    /// `steady|build|peakRelease|windDown|wave|custom` (§14.3).
    public var arcKind: String
    /// Canonical `EnergyArc` parameter payload (`level`/`peakAt`/`cycles`/`points`).
    public var arcPointsJSON: String?
    /// XOR with `targetTrackCount` (FR-PLIST-2's T).
    public var targetSeconds: Int?
    public var targetTrackCount: Int?
    /// Canonical `.sortedKeys` encoding of `SequencingConstraints`.
    public var constraintsJSON: String
    public var seedTrackID: Int64?
    public var seedCrateID: Int64?
    /// Seeded tie-break; `UInt64(bitPattern:)` round-trips (§28A.3, NFR-DET-1).
    public var randomSeed: Int64
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil,
                syncID: String,
                prompt: String,
                arcKind: String,
                arcPointsJSON: String? = nil,
                targetSeconds: Int? = nil,
                targetTrackCount: Int? = nil,
                constraintsJSON: String,
                seedTrackID: Int64? = nil,
                seedCrateID: Int64? = nil,
                randomSeed: Int64,
                createdAt: Date,
                updatedAt: Date) {
        self.id = id
        self.syncID = syncID
        self.prompt = prompt
        self.arcKind = arcKind
        self.arcPointsJSON = arcPointsJSON
        self.targetSeconds = targetSeconds
        self.targetTrackCount = targetTrackCount
        self.constraintsJSON = constraintsJSON
        self.seedTrackID = seedTrackID
        self.seedCrateID = seedCrateID
        self.randomSeed = randomSeed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The arc the row stores, decoded from `arcKind` + `arcPointsJSON` (§2).
    public var arc: EnergyArc? {
        EnergyArc.from(kindCode: arcKind, pointsJSON: arcPointsJSON)
    }

    /// The constraints the row stores, decoded byte-exact from `constraintsJSON`.
    public var constraints: SequencingConstraints? {
        try? SequencingConstraints.decodeJSON(constraintsJSON)
    }

    public var seed: UInt64 { UInt64(bitPattern: randomSeed) }

    public static let databaseTableName = "auto_playlist_brief"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// The generated sequence + its headline scoring (§14.3): total seconds, mean
/// |actual − target| arc error, mean transition cost, and the analysis version
/// that produced the embedding scores (`AnalysisVersions.embedding`).
public struct AutoPlaylistResult: Codable, Identifiable, FetchableRecord,
                                  MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var briefID: Int64
    public var playlistID: Int64?
    public var smartCrateID: Int64?
    public var generatedAt: Date
    public var totalSeconds: Int
    /// Mean |actual − target| energy, 0...1 (§28A.5).
    public var arcError: Double
    /// §28A.1's mean transition cost over adjacent pairs.
    public var meanTransitionCost: Double
    public var analysisVersion: Int

    public init(id: Int64? = nil,
                briefID: Int64,
                playlistID: Int64? = nil,
                smartCrateID: Int64? = nil,
                generatedAt: Date,
                totalSeconds: Int,
                arcError: Double,
                meanTransitionCost: Double,
                analysisVersion: Int) {
        self.id = id
        self.briefID = briefID
        self.playlistID = playlistID
        self.smartCrateID = smartCrateID
        self.generatedAt = generatedAt
        self.totalSeconds = totalSeconds
        self.arcError = arcError
        self.meanTransitionCost = meanTransitionCost
        self.analysisVersion = analysisVersion
    }

    public static let databaseTableName = "auto_playlist_result"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One slot of a generated sequence (§14.3): which track, its position, its
/// lock state (FR-PLIST-6), the arc's [0,1] target and the track's CDF rank, the
/// transition cost from the previous slot, and its semantic score.
public struct AutoPlaylistItem: Codable, Identifiable, FetchableRecord,
                                MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var resultID: Int64
    public var trackID: Int64
    public var position: Int
    public var locked: Bool
    /// The [0,1] arc value at this slot (§28A.5).
    public var targetEnergy: Double
    /// The track's empirical-CDF energy rank, [0,1]; neutral 0.5 when unanalysed.
    public var actualEnergy: Double
    /// Cost from the previous slot; nil/0 at the head (§14.3).
    public var transitionCostIn: Double?
    public var semanticScore: Double

    public init(id: Int64? = nil,
                resultID: Int64,
                trackID: Int64,
                position: Int,
                locked: Bool = false,
                targetEnergy: Double,
                actualEnergy: Double,
                transitionCostIn: Double?,
                semanticScore: Double) {
        self.id = id
        self.resultID = resultID
        self.trackID = trackID
        self.position = position
        self.locked = locked
        self.targetEnergy = targetEnergy
        self.actualEnergy = actualEnergy
        self.transitionCostIn = transitionCostIn
        self.semanticScore = semanticScore
    }

    public static let databaseTableName = "auto_playlist_item"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A track the user said no to, remembered against the brief (§28A.4) so the
/// next generation is visibly better. Semantically unique on (briefID, trackID);
/// the dj_v1 index is non-unique (matching §14.3 verbatim), so `upsertRejections`
/// de-duplicates in code.
public struct AutoPlaylistRejection: Codable, Identifiable, FetchableRecord,
                                     MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var briefID: Int64
    public var trackID: Int64
    public var rejectedAt: Date

    public init(id: Int64? = nil, briefID: Int64, trackID: Int64, rejectedAt: Date) {
        self.id = id
        self.briefID = briefID
        self.trackID = trackID
        self.rejectedAt = rejectedAt
    }

    public static let databaseTableName = "auto_playlist_rejection"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A static playlist row in the DJ database (FR-PLIST-7 "Save as Playlist").
/// DJ-prefixed because `TonearmCore` already owns a `Playlist` record.
public struct DJPlaylist: Codable, Identifiable, FetchableRecord,
                          MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var title: String
    /// `manual|performance` (§14.3); a saved generated playlist is `manual`.
    public var kind: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil, syncID: String, title: String,
                kind: String = "manual", createdAt: Date, updatedAt: Date) {
        self.id = id
        self.syncID = syncID
        self.title = title
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "playlist"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One ordered row of a static DJ playlist (§14.3).
public struct DJPlaylistItem: Codable, Identifiable, FetchableRecord,
                              MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var playlistID: Int64
    public var trackID: Int64
    public var position: Int

    public init(id: Int64? = nil, playlistID: Int64, trackID: Int64, position: Int) {
        self.id = id
        self.playlistID = playlistID
        self.trackID = trackID
        self.position = position
    }

    public static let databaseTableName = "playlist_item"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
