import Foundation
import GRDB


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

// MARK: - Persisted analysis artifacts (read side; §19.4, §10.1 façade)

/// One `downbeat` row — a bar start, the anchor for phrase display and bar
/// numbering (§15.3, §19.4).
public struct DownbeatRecord: Codable, FetchableRecord, Equatable, Sendable {
    public var beatIndex: Int
    public var samplePosition: Int64
    /// 1-based bar number, in the order the downbeats appear in the track.
    public var barNumber: Int
    public var confidence: Double?

    public init(beatIndex: Int, samplePosition: Int64, barNumber: Int,
                confidence: Double? = nil) {
        self.beatIndex = beatIndex
        self.samplePosition = samplePosition
        self.barNumber = barNumber
        self.confidence = confidence
    }
}

/// The decoded `energy_curve` readout — the per-beat energy BLOB backing the
/// prep energy display (§19.4, §15.7 `kind=0x04`).
public struct EnergyCurve: Equatable, Sendable {
    /// `beat|frame` — M5's pipeline always writes the per-beat curve.
    public var resolution: String
    /// The curve in `0...1`.
    public var values: [Float]
    /// The STFT hop-seconds the curve was built at.
    public var hopSeconds: Double

    public init(resolution: String, values: [Float], hopSeconds: Double) {
        self.resolution = resolution
        self.values = values
        self.hopSeconds = hopSeconds
    }
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

// `DJTrackEmbedding`/`DJWindowEmbedding` (the `track_embedding`/
// `window_embedding` tables) were deleted in dj_v12 (C02): they backed the
// semantic-search subsystem (`VectorStore`/`SemanticSearchService`/
// `EmbeddingCoordinator`), which was already removed from `Sources` before
// that migration was written, and both referenced the now-deleted DJ-local
// `track` catalog table. `embedding_version`/`vector_matrix_meta` do not
// reference `track` and are untouched.

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

// MARK: - Recording journal (§15.5, §37.3; plan 5.11)

/// The `mix.localState` — the §37.3 journal's honest state machine. `recording`
/// is the in-progress journal row; `complete` is a finished mix; `corrupt` is a
/// journal row whose recording could not be salvaged on reconcile. The schema
/// column is text (matching §15.5 verbatim); this is the typed view.
public enum MixLocalState: String, Codable, Sendable, Equatable, CaseIterable {
    case recording
    case complete
    case corrupt

    public init?(rawValue: String?) {
        guard let rawValue else { return nil }
        self.init(rawValue: rawValue)
    }
}

/// One `mix` row — the §37.3 recording journal AND the finished mix's header
/// (FR-REC-1). The row is written **in-progress** when recording starts
/// (`localState = .recording`); `finalize` promotes it to `.complete` with the
/// real duration/size; `reconcile()` salvages a crash's stale `recording` row
/// to `.complete` (segments joined) or `.corrupt` (nothing recoverable).
public struct DJMix: Codable, Identifiable, FetchableRecord,
                     MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var sessionID: Int64?
    public var title: String
    public var notes: String?
    public var durationSec: Double
    public var trackCount: Int
    /// The FR-REC-7 honest format name (`RecordingEncoder.formatName`).
    public var format: String
    public var bitrateKbps: Int?
    public var sizeBytes: Int64?
    public var artworkID: String?
    public var recordedAt: Date
    /// `localOnly|syncToPhone` (§15.5). `localOnly` is the default; sync is M6.
    public var syncPolicy: String
    /// `recording|complete|corrupt` (§15.5, §37.3).
    public var localState: String

    public init(id: Int64? = nil,
                syncID: String,
                sessionID: Int64? = nil,
                title: String,
                notes: String? = nil,
                durationSec: Double,
                trackCount: Int,
                format: String,
                bitrateKbps: Int? = nil,
                sizeBytes: Int64? = nil,
                artworkID: String? = nil,
                recordedAt: Date,
                syncPolicy: String = "localOnly",
                localState: String) {
        self.id = id
        self.syncID = syncID
        self.sessionID = sessionID
        self.title = title
        self.notes = notes
        self.durationSec = durationSec
        self.trackCount = trackCount
        self.format = format
        self.bitrateKbps = bitrateKbps
        self.sizeBytes = sizeBytes
        self.artworkID = artworkID
        self.recordedAt = recordedAt
        self.syncPolicy = syncPolicy
        self.localState = localState
    }

    /// The §37.3 journal state, typed.
    public var state: MixLocalState {
        MixLocalState(rawValue: localState) ?? .corrupt
    }

    public static let databaseTableName = "mix"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One `mix_asset` row — the recording's local file + CKAsset lifecycle
/// (§15.5, §38.6). `localRelPath` is the final joined M4A relative to
/// `DJDatabase.mixesDirectory` (e.g. `<sessionUUID>/mix.m4a`), recorded at
/// `begin` and confirmed at `finalize`. Sync columns are inert until M6.
public struct DJMixAsset: Codable, FetchableRecord,
                          MutablePersistableRecord, Equatable, Sendable {
    public var mixID: Int64
    public var localRelPath: String
    public var ckRecordName: String?
    public var ckAssetUploaded: Bool
    public var uploadedBytes: Int64
    public var totalBytes: Int64?
    public var lastUploadAt: Date?

    public init(mixID: Int64,
                localRelPath: String,
                ckRecordName: String? = nil,
                ckAssetUploaded: Bool = false,
                uploadedBytes: Int64 = 0,
                totalBytes: Int64? = nil,
                lastUploadAt: Date? = nil) {
        self.mixID = mixID
        self.localRelPath = localRelPath
        self.ckRecordName = ckRecordName
        self.ckAssetUploaded = ckAssetUploaded
        self.uploadedBytes = uploadedBytes
        self.totalBytes = totalBytes
        self.lastUploadAt = lastUploadAt
    }

    public static let databaseTableName = "mix_asset"
}

/// The snapshot `RecordingService` resolves for a timeline track at finalize
/// (§37.4, plan 5.12): the `mix_track_event` title/artist/BPM/key columns are
/// filled from it so the timeline survives track deletion (§15.5).
public struct TrackTimelineSnapshot: Sendable, Equatable {
    public let title: String
    public let artist: String?
    public let bpm: Double?
    public let camelot: String?

    public init(title: String, artist: String?, bpm: Double?, camelot: String?) {
        self.title = title
        self.artist = artist
        self.bpm = bpm
        self.camelot = camelot
    }
}

/// One `mix_track_event` row — the recorded journal of *what happened when*
/// (§37.4, FR-REC-2, dj-regression-suite §7). Written by 5.12's `MixTimeline`;
/// the record ships here so the schema is complete and the regression suite's
/// journal cross-check has a row shape. `title`/`artist` are snapshots so the
/// timeline survives track deletion; `position` is 1..n order.
public struct DJMixTrackEvent: Codable, Identifiable, FetchableRecord,
                               MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var mixID: Int64
    public var trackID: Int64?
    public var title: String
    public var artist: String?
    public var deck: String
    public var startOffsetSec: Double
    public var bpmAtPlay: Double?
    public var camelotAtPlay: String?
    public var position: Int

    public init(id: Int64? = nil,
                mixID: Int64,
                trackID: Int64? = nil,
                title: String,
                artist: String? = nil,
                deck: String,
                startOffsetSec: Double,
                bpmAtPlay: Double? = nil,
                camelotAtPlay: String? = nil,
                position: Int) {
        self.id = id
        self.mixID = mixID
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.deck = deck
        self.startOffsetSec = startOffsetSec
        self.bpmAtPlay = bpmAtPlay
        self.camelotAtPlay = camelotAtPlay
        self.position = position
    }

    public static let databaseTableName = "mix_track_event"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One `performance_session` row — a DJ set in progress or completed (§15.5).
/// `mix.sessionID` is nullable; the session row is created when the milestone's
/// set-level surface lands (M6), not by the per-mix journal.
public struct DJPerformanceSession: Codable, Identifiable, FetchableRecord,
                                    MutablePersistableRecord, Equatable, Sendable {
    public var id: Int64?
    public var syncID: String
    public var startedAt: Date
    public var endedAt: Date?
    public var deckAStartTrackID: Int64?
    public var deckBStartTrackID: Int64?

    public init(id: Int64? = nil,
                syncID: String,
                startedAt: Date,
                endedAt: Date? = nil,
                deckAStartTrackID: Int64? = nil,
                deckBStartTrackID: Int64? = nil) {
        self.id = id
        self.syncID = syncID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.deckAStartTrackID = deckAStartTrackID
        self.deckBStartTrackID = deckBStartTrackID
    }

    public static let databaseTableName = "performance_session"
    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
