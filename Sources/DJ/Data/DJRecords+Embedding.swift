import Foundation
import GRDB

// MARK: - dj_v3 embedding rows (§15.4)
//
// Split out of `DJRecords.swift` — no cross-file access-level changes needed,
// these are standalone record types with no shared private state.

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
