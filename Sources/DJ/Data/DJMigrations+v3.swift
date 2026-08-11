import Foundation
import GRDB

extension DJMigrations {
    /// `dj_v3` — Stage 2 embeddings (§15.4, plan §4). Append-only; no existing
    /// table changes. `embedding_version` is seeded with version 1 (the real
    /// music-CLAP model) so `AnalysisVersions.embedding` has a registry row from
    /// the moment the stage is runnable.
    static func registerV3(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("dj_v3") { db in

            // ---- embedding_version (registry of model sets; §15.4, §27.1) ----
            try db.create(table: "embedding_version") { t in
                t.column("version", .integer).notNull()
                t.column("modelName", .text).notNull()      // e.g. "music_audioset_epoch_15_esc_90.14"
                t.column("dimensions", .integer).notNull()  // 512
                t.column("windowSeconds", .double).notNull()
                t.column("hopSeconds", .double).notNull()
                t.column("pooling", .text).notNull()        // mean|attention
                t.column("introducedAt", .datetime).notNull()
                t.primaryKey(["version"])
            }

            // ---- track_embedding (whole-track pooled vector; §15.4) ----
            // Library-wide, int8-quantized per §16.6. `vector` is raw Int8[dims],
            // L2-normalized-then-quantized, no header. `matrixRow` is the row in
            // `vectors.i8` for Tier A; NULL once tombstoned (§16.7).
            try db.create(table: "track_embedding") { t in
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("dims", .integer).notNull()
                t.column("vector", .blob).notNull()
                t.column("scale", .double).notNull()        // per-row dequantization scale (§16.6)
                t.column("matrixRow", .integer)
                t.column("version", .integer).notNull()
                t.primaryKey(["trackID"])
            }
            try db.create(index: "idx_trackemb_row", on: "track_embedding", columns: ["matrixRow"])

            // ---- window_embedding (per-window vectors; §15.4, §16.4) ----
            // CRATE-SCOPED: rows exist only while a crate referencing the track
            // is prepared; deleting the crate deletes them.
            try db.create(table: "window_embedding") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("trackID", .integer).notNull().references("track", onDelete: .cascade)
                t.column("windowIndex", .integer).notNull()
                t.column("startSample", .integer).notNull()
                t.column("endSample", .integer).notNull()
                t.column("vector", .blob).notNull()         // Int8[dims], L2-normalized then quantized
                t.column("scale", .double).notNull()
                t.column("version", .integer).notNull()
            }
            try db.create(index: "idx_winemb_track", on: "window_embedding",
                          columns: ["trackID", "windowIndex"])

            // ---- vector_matrix_meta (Tier A bookkeeping; §15.4, §16.2) ----
            try db.create(table: "vector_matrix_meta") { t in
                t.column("id", .integer).notNull()          // singleton row, always 1
                t.column("rowCount", .integer).notNull()
                t.column("tombstoneCount", .integer).notNull()
                t.column("dims", .integer).notNull()
                t.column("tier", .text).notNull()           // "A" (brute-force) | "B" (sqlite-vec)
                t.column("lastCompactedAt", .datetime)
                t.primaryKey(["id"])
            }

            // Seed the registry with the active model (§27.1, plan §5 2.1). The
            // metadata is the real music-CLAP model; pooling default is attention.
            try db.execute(sql: """
                INSERT INTO embedding_version
                (version, modelName, dimensions, windowSeconds, hopSeconds, pooling, introducedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [AnalysisVersions.embedding,
                                 EmbeddingModelSpec.musicCLAPMetadata.modelName,
                                 EmbeddingModelSpec.musicCLAPMetadata.dimensions,
                                 EmbeddingModelSpec.musicCLAPMetadata.windowSeconds,
                                 EmbeddingModelSpec.musicCLAPMetadata.hopSeconds,
                                 EmbeddingModelSpec.musicCLAPMetadata.pooling.rawValue,
                                 Date()])
        }
    }
}
