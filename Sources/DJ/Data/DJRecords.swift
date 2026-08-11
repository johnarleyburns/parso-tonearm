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
