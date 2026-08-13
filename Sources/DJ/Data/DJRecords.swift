import Foundation
import GRDB

// Record names are DJ-prefixed where the same name already exists in
// `TonearmCore` (artist, album, asset) so a file importing both modules stays
// unambiguous; `DJTrack` follows the spec's own §18.1 naming.

public struct DJArtist: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var name: String
    public var sortName: String
    public var createdAt: Date

    public init(id: Int64? = nil,
                syncID: String,
                name: String,
                sortName: String,
                createdAt: Date) {
        self.id = id
        self.syncID = syncID
        self.name = name
        self.sortName = sortName
        self.createdAt = createdAt
    }
}
extension DJArtist: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "artist"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct DJAlbum: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var title: String
    public var albumArtist: String?
    public var year: Int?
    public var artworkID: String?
    public var createdAt: Date

    public init(id: Int64? = nil,
                syncID: String,
                title: String,
                albumArtist: String? = nil,
                year: Int? = nil,
                artworkID: String? = nil,
                createdAt: Date) {
        self.id = id
        self.syncID = syncID
        self.title = title
        self.albumArtist = albumArtist
        self.year = year
        self.artworkID = artworkID
        self.createdAt = createdAt
    }
}
extension DJAlbum: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "album"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct DJTrack: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var albumID: Int64?
    public var title: String
    public var trackNo: Int?
    public var discNo: Int?
    public var durationSec: Double?
    public var codec: String?
    public var sampleRate: Int?
    public var channelCount: Int?
    public var bitDepthOrBitrate: String?
    public var contentHash: String
    public var sortKey: String
    public var bpm: Double?
    public var detectedBPM: Double?
    public var camelot: String?
    public var musicalKey: String?
    public var energy: Double?
    public var analysisVersion: Int
    public var embeddingVersion: Int
    public var analysisState: String
    public var stemState: String
    public var addedAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil,
                syncID: String,
                albumID: Int64? = nil,
                title: String,
                trackNo: Int? = nil,
                discNo: Int? = nil,
                durationSec: Double? = nil,
                codec: String? = nil,
                sampleRate: Int? = nil,
                channelCount: Int? = nil,
                bitDepthOrBitrate: String? = nil,
                contentHash: String,
                sortKey: String,
                bpm: Double? = nil,
                detectedBPM: Double? = nil,
                camelot: String? = nil,
                musicalKey: String? = nil,
                energy: Double? = nil,
                analysisVersion: Int = 0,
                embeddingVersion: Int = 0,
                analysisState: String = "pending",
                stemState: String = "none",
                addedAt: Date,
                updatedAt: Date) {
        self.id = id
        self.syncID = syncID
        self.albumID = albumID
        self.title = title
        self.trackNo = trackNo
        self.discNo = discNo
        self.durationSec = durationSec
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepthOrBitrate = bitDepthOrBitrate
        self.contentHash = contentHash
        self.sortKey = sortKey
        self.bpm = bpm
        self.detectedBPM = detectedBPM
        self.camelot = camelot
        self.musicalKey = musicalKey
        self.energy = energy
        self.analysisVersion = analysisVersion
        self.embeddingVersion = embeddingVersion
        self.analysisState = analysisState
        self.stemState = stemState
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }
}
extension DJTrack: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "track"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct DJAsset: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var trackID: Int64
    public var folderID: Int64?
    public var bookmark: Data?
    public var relPath: String?
    public var sizeBytes: Int64?
    public var fileModifiedAt: Date?
    public var unsupportedReason: String?

    public init(id: Int64? = nil,
                trackID: Int64,
                folderID: Int64? = nil,
                bookmark: Data? = nil,
                relPath: String? = nil,
                sizeBytes: Int64? = nil,
                fileModifiedAt: Date? = nil,
                unsupportedReason: String? = nil) {
        self.id = id
        self.trackID = trackID
        self.folderID = folderID
        self.bookmark = bookmark
        self.relPath = relPath
        self.sizeBytes = sizeBytes
        self.fileModifiedAt = fileModifiedAt
        self.unsupportedReason = unsupportedReason
    }
}
extension DJAsset: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "asset"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct DJFolder: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var displayPath: String
    public var bookmark: Data
    public var watching: Bool
    public var addedAt: Date
    public var lastScanAt: Date?

    public init(id: Int64? = nil,
                syncID: String,
                displayPath: String,
                bookmark: Data,
                watching: Bool = true,
                addedAt: Date,
                lastScanAt: Date? = nil) {
        self.id = id
        self.syncID = syncID
        self.displayPath = displayPath
        self.bookmark = bookmark
        self.watching = watching
        self.addedAt = addedAt
        self.lastScanAt = lastScanAt
    }
}
extension DJFolder: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "folder"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct DJImportEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: Int64?
    public var trackID: Int64?
    public var kind: String
    public var detail: String?
    public var at: Date

    public init(id: Int64? = nil,
                trackID: Int64? = nil,
                kind: String,
                detail: String? = nil,
                at: Date) {
        self.id = id
        self.trackID = trackID
        self.kind = kind
        self.detail = detail
        self.at = at
    }
}
extension DJImportEvent: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "import_event"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - grid_correction (authoritative user override log; FR-ANL-5, §23.3)

/// One row of the authoritative user grid-override log (§14.3, FR-ANL-5).
/// Edits are **appended**, never in-place, so the immutable detected analysis
/// survives and the corrections replay deterministically over it (§23.3) to
/// produce the authoritative `beat_grid` (`source = corrected`).
public struct GridCorrection: Codable, Identifiable, FetchableRecord,
                              MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var trackID: Int64
    /// The `GridCorrectionOp` raw value (`nudge|setDownbeat|doubleBPM|halveBPM|setBPM|shift`).
    public var op: String
    /// e.g. the new BPM for `setBPM`.
    public var valueDouble: Double?
    /// e.g. the sample offset for `nudge`/`shift`, the sample for `setDownbeat`.
    public var valueInt: Int64?
    public var appliedAt: Date

    public init(id: Int64? = nil,
                syncID: String,
                trackID: Int64,
                op: String,
                valueDouble: Double? = nil,
                valueInt: Int64? = nil,
                appliedAt: Date) {
        self.id = id
        self.syncID = syncID
        self.trackID = trackID
        self.op = op
        self.valueDouble = valueDouble
        self.valueInt = valueInt
        self.appliedAt = appliedAt
    }

    public static let databaseTableName = "grid_correction"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// The grid-correction operations the prep surface can append (FR-PREP-5,
/// §14.3): tap-to-set-downbeat, drag-to-nudge, ×2 / ÷2, set BPM (tempo tap)
/// and the two-finger shift. Raw values are the `grid_correction.op` column.
public enum GridCorrectionOp: String, CaseIterable, Sendable, Equatable {
    /// Drag-nudge: shift the grid by a sample delta (`valueInt`).
    case nudge
    /// Tap-to-set-downbeat: make `valueInt` the sample of grid beat 0.
    case setDownbeat
    /// ×2 BPM.
    case doubleBPM
    /// ÷2 BPM.
    case halveBPM
    /// Set an explicit BPM (tempo tap) — `valueDouble`.
    case setBPM
    /// Two-finger nudge: shift the grid by a sample delta (`valueInt`).
    case shift
}

// MARK: - dj_v3 embedding rows (§15.4)

/// Registry of embedding model sets; seeded by the `dj_v3` migration (§27.1).
public struct DJEmbeddingVersion: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public var version: Int
    public var modelName: String
    public var dimensions: Int
    public var windowSeconds: Double
    public var hopSeconds: Double
    public var pooling: String
    public var introducedAt: Date

    public init(version: Int, modelName: String, dimensions: Int,
                windowSeconds: Double, hopSeconds: Double,
                pooling: String, introducedAt: Date) {
        self.version = version
        self.modelName = modelName
        self.dimensions = dimensions
        self.windowSeconds = windowSeconds
        self.hopSeconds = hopSeconds
        self.pooling = pooling
        self.introducedAt = introducedAt
    }
    public static let databaseTableName = "embedding_version"
}

/// One track's pooled whole-track vector, int8-quantized (§15.4, §16.6).
/// `vector` is raw `Int8[dims]` — L2-normalized then quantized, no header.
public struct DJTrackEmbedding: Codable, FetchableRecord, MutablePersistableRecord,
                                Equatable, Sendable {
    public var trackID: Int64
    public var dims: Int
    public var vector: Data
    public var scale: Double
    public var matrixRow: Int?
    public var version: Int

    public init(trackID: Int64, dims: Int, vector: Data, scale: Double,
                matrixRow: Int?, version: Int) {
        self.trackID = trackID
        self.dims = dims
        self.vector = vector
        self.scale = scale
        self.matrixRow = matrixRow
        self.version = version
    }

    public init(trackID: Int64, int8Vector: [Int8], scale: Double,
                matrixRow: Int?, version: Int) {
        self.trackID = trackID
        self.dims = int8Vector.count
        self.vector = int8Vector.withUnsafeBufferPointer { Data(buffer: $0) }
        self.scale = scale
        self.matrixRow = matrixRow
        self.version = version
    }

    public var int8Vector: [Int8] {
        vector.withUnsafeBytes { Array($0.bindMemory(to: Int8.self)) }
    }

    public static let databaseTableName = "track_embedding"
}

/// Per-window vectors — crate-scoped (§15.4, §16.4): rows exist only while a
/// crate referencing the track is prepared.
public struct DJWindowEmbedding: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public var id: Int64?
    public var trackID: Int64
    public var windowIndex: Int
    public var startSample: Int64
    public var endSample: Int64
    public var vector: Data
    public var scale: Double
    public var version: Int

    public init(id: Int64? = nil, trackID: Int64, windowIndex: Int,
                startSample: Int64, endSample: Int64, vector: Data,
                scale: Double, version: Int) {
        self.id = id
        self.trackID = trackID
        self.windowIndex = windowIndex
        self.startSample = startSample
        self.endSample = endSample
        self.vector = vector
        self.scale = scale
        self.version = version
    }

    public static let databaseTableName = "window_embedding"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// Tier A matrix bookkeeping (§15.4, §16.2). Singleton row with id == 1.
public struct DJVectorMatrixMeta: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    public var id: Int64
    public var rowCount: Int
    public var tombstoneCount: Int
    public var dims: Int
    public var tier: String
    public var lastCompactedAt: Date?

    public init(id: Int64, rowCount: Int, tombstoneCount: Int, dims: Int,
                tier: String, lastCompactedAt: Date?) {
        self.id = id
        self.rowCount = rowCount
        self.tombstoneCount = tombstoneCount
        self.dims = dims
        self.tier = tier
        self.lastCompactedAt = lastCompactedAt
    }
    public static let databaseTableName = "vector_matrix_meta"
}

// MARK: - Smart crates (§14, FR-SEM-5)

/// A saved `VibeQuery` that re-evaluates live against whatever the library has
/// now (§14, mockup `ipad/04b` "Save as Smart Crate"). The full-fidelity query
/// lives in `queryJSON`; the normalized `crate_rule` rows let relational filters
/// read the musical constraints without decoding (§14.3).
public struct SmartCrate: Codable, Identifiable, FetchableRecord,
                          MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var name: String
    /// Encoded `VibeQuery` — the crate IS the query, not a frozen list.
    public var queryJSON: String
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: Int64? = nil,
                syncID: String,
                name: String,
                queryJSON: String,
                pinned: Bool = false,
                createdAt: Date,
                updatedAt: Date) {
        self.id = id
        self.syncID = syncID
        self.name = name
        self.queryJSON = queryJSON
        self.pinned = pinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "smart_crate"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A normalized musical constraint of a smart crate (§14.3): a filter that a
/// relational query can read without decoding `smart_crate.queryJSON`.
public struct CrateRule: Codable, Identifiable, FetchableRecord,
                         MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var crateID: Int64
    /// `bpm | camelot | energy | genre | rating | addedAt` (§14.3).
    public var field: String
    /// `between | eq | gte | lte | in` (§14.3).
    public var op: String
    /// JSON-encoded operand, e.g. `[118,132]` for bpm `between`.
    public var valueJSON: String

    public init(id: Int64? = nil, crateID: Int64, field: String, op: String,
                valueJSON: String) {
        self.id = id
        self.crateID = crateID
        self.field = field
        self.op = op
        self.valueJSON = valueJSON
    }

    public static let databaseTableName = "crate_rule"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

// MARK: - Auto-playlists (§14.3, plan M3 commit 3.3)

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
