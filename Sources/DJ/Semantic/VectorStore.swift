import Foundation
import GRDB

/// The store façade over the whole-track vector space (§16). Tier A is the
/// brute-force implementation (built on `ParsoAudioNeural.VectorMatrixScanner`,
/// Phase 7b); Tier B (sqlite-vec) is deferred and would implement the same
/// surface.
public protocol VectorStore: Sendable {
    var dims: Int { get }
    var rowCount: Int { get }
    var tombstoneCount: Int { get }

    /// Upsert one track's pooled vector: append to the matrix, write
    /// `track_embedding`, bump `vector_matrix_meta` — inside `db`'s active
    /// transaction, so the caller persists track + embedding + index atomically
    /// (§16.5). The matrix file itself is append-only and regenerable; a crash
    /// between the append and the commit leaves an orphan row the scan never
    /// sees (it is clamped out by `vector_matrix_meta.rowCount`).
    func upsert(_ embedding: DJTrackEmbedding, db: Database) throws

    /// Tombstone a track's matrix row (`matrixRow = NULL`, §16.7). The vector
    /// stays in `track_embedding`; compaction reclaims the matrix slot.
    func remove(trackID: Int64, db: Database) throws

    /// Top-K live rows by cosine similarity (== dot for normalized vectors),
    /// cancellable between scan blocks. `VectorMatch.rowID` is the trackID.
    func search(query: [Float], topK: Int,
                isCancelled: @escaping @Sendable () -> Bool) throws -> [VectorMatch]

    /// Rewrite the matrix without tombstones when tombstones exceed 20% (§16.7).
    func compactIfNeeded() throws

    /// Rebuild `vectors.i8` from `track_embedding` — the source of truth
    /// (§16.5). Deterministic: byte-identical regeneration (NFR-DET-3).
    func rebuildMatrix() throws
}

/// Tier A: append-only `vectors.i8` under `DJDatabase.cachesDirectory` (§13.1),
/// mmap'd read-only scans via `ParsoAudioNeural.VectorMatrixScanner`,
/// fixed-min-heap top-K, cancellable between blocks, tombstone + compaction
/// (§16.2, §16.7).
public struct VectorStoreTierA: VectorStore {
    public let dims: Int
    public let pool: DatabasePool
    public let fileURL: URL

    public init(pool: DatabasePool, dims: Int, fileURL: URL? = nil) throws {
        self.pool = pool
        self.dims = dims
        self.fileURL = fileURL ?? DJDatabase.cachesDirectory
            .appendingPathComponent("vectors.i8")
        // The singleton meta row is the bookkeeping anchor (§15.4).
        try pool.write { db in
            if try DJVectorMatrixMeta.fetchAll(db).isEmpty {
                var meta = DJVectorMatrixMeta(id: 1, rowCount: 0, tombstoneCount: 0,
                                              dims: dims, tier: "A", lastCompactedAt: nil)
                try meta.insert(db)
            }
        }
        // Ensure the matrix file exists so `search` and `appendRow` never hit a
        // missing-file error; an empty matrix scans to no matches (§16.2).
        if !FileManager.default.fileExists(atPath: self.fileURL.path) {
            FileManager.default.createFile(atPath: self.fileURL.path, contents: Data())
        }
    }

    public var rowCount: Int {
        (try? pool.read { try DJVectorMatrixMeta.filter(Column("id") == 1).fetchOne($0)?.rowCount })
            ?? 0
    }

    public var tombstoneCount: Int {
        (try? pool.read { try DJVectorMatrixMeta.filter(Column("id") == 1).fetchOne($0)?.tombstoneCount })
            ?? 0
    }

    public func upsert(_ embedding: DJTrackEmbedding, db: Database) throws {
        let row = try DJVectorMatrixMeta.filter(Column("id") == 1).fetchOne(db)?.rowCount ?? 0
        try appendRow(embedding, at: row)
        var stored = embedding
        stored.matrixRow = row
        try stored.save(db)
        try db.execute(sql: "UPDATE vector_matrix_meta SET rowCount = rowCount + 1 WHERE id = 1")
    }

    public func remove(trackID: Int64, db: Database) throws {
        guard let embedding = try DJTrackEmbedding
            .filter(Column("trackID") == trackID).fetchOne(db),
            embedding.matrixRow != nil else { return }
        var updated = embedding
        updated.matrixRow = nil
        try updated.update(db)
        try db.execute(sql: "UPDATE vector_matrix_meta SET tombstoneCount = tombstoneCount + 1 WHERE id = 1")
    }

    public func search(query: [Float], topK: Int,
                       isCancelled: @escaping @Sendable () -> Bool) throws -> [VectorMatch] {
        let mapping = try pool.read { db -> [Int64: Int64] in
            let rows = try DJTrackEmbedding
                .filter(Column("matrixRow") != nil)
                .fetchAll(db)
            var map: [Int64: Int64] = [:]
            for embedding in rows {
                if let matrixRow = embedding.matrixRow {
                    map[Int64(matrixRow)] = embedding.trackID
                }
            }
            return map
        }
        let matrix = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return VectorMatrixScanner.scan(matrix: matrix, dims: dims, query: query,
                                        rowMapping: mapping, topK: topK,
                                        isCancelled: isCancelled)
    }

    public func compactIfNeeded() throws {
        try pool.write { db in
            guard let meta = try DJVectorMatrixMeta.filter(Column("id") == 1).fetchOne(db),
                  meta.rowCount > 0 else { return }
            let ratio = Double(meta.tombstoneCount) / Double(meta.rowCount)
            guard ratio > 0.2 else { return }
            try compact(db)
        }
    }

    public func rebuildMatrix() throws {
        try pool.write { db in try compact(db) }
    }

    // MARK: - Matrix I/O

    /// Append one row (scale prefix + raw Int8[dims]) at physical row `index`.
    private func appendRow(_ embedding: DJTrackEmbedding, at index: Int) throws {
        var data = Data(capacity: VectorMatrixScanner.rowBytes(dims: dims))
        var scale = Float(embedding.scale)
        withUnsafeBytes(of: &scale) { data.append(contentsOf: $0) }
        data.append(embedding.vector)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Rewrite the matrix from the live rows in `track_embedding` (source of
    /// truth, §16.5): same bytes as the incremental appends that built it
    /// (NFR-DET-3), contiguous `matrixRow`, tombstones dropped, meta reset.
    private func compact(_ db: Database) throws {
        let rows = try DJTrackEmbedding
            .filter(Column("matrixRow") != nil)
            .order(Column("matrixRow"))
            .fetchAll(db)
        var data = Data(capacity: rows.count * VectorMatrixScanner.rowBytes(dims: dims))
        for (index, row) in rows.enumerated() {
            var scale = Float(row.scale)
            withUnsafeBytes(of: &scale) { data.append(contentsOf: $0) }
            data.append(row.vector)
            var updated = row
            updated.matrixRow = index
            try updated.update(db)
        }
        try data.write(to: fileURL, options: .atomic)
        if let meta = try DJVectorMatrixMeta.filter(Column("id") == 1).fetchOne(db) {
            var newMeta = meta
            newMeta.rowCount = rows.count
            newMeta.tombstoneCount = 0
            newMeta.lastCompactedAt = Date()
            try newMeta.update(db)
        }
    }
}
