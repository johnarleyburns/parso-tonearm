import Foundation
import GRDB
import Accelerate

/// One search hit: the track and its cosine similarity (≈ dot for normalized
/// vectors) to the query.
public struct VectorMatch: Sendable, Equatable {
    public let trackID: Int64
    public let similarity: Float

    public init(trackID: Int64, similarity: Float) {
        self.trackID = trackID
        self.similarity = similarity
    }
}

/// The Tier A brute-force cosine scanner (§16.2). Pure: takes the mmap'd matrix
/// bytes and the query, returns the fixed-min-heap top-K. Deterministic
/// (NFR-DET-3) and benchmarkable in isolation.
///
/// `vectors.i8` row layout: `Float32 scale (LE) + Int8[dims]`. The per-row
/// scale dequantizes the int8 row in one multiply, so a scan is a block
/// `vDSP_vflt8` + `vDSP_dotpr` per row — no per-element Swift work.
public enum VectorMatrixScanner {
    /// Bytes of the per-row scale prefix.
    public static let scaleByteCount = 4

    public static func rowBytes(dims: Int) -> Int { scaleByteCount + dims }

    /// Scan for the top-K nearest live rows. `query` must be L2-normalized.
    /// `rowMapping` maps physical row → trackID for live rows; rows absent from
    /// it (tombstoned/orphaned) are skipped. Pass nil to treat every row as live
    /// with identity trackIDs (the benchmark shape). `isCancelled` is polled
    /// between blocks so a UI request can abandon the scan.
    public static func scan(matrix: Data,
                            dims: Int,
                            query: [Float],
                            rowMapping: [Int64: Int64]?,
                            topK: Int,
                            isCancelled: @escaping @Sendable () -> Bool) -> [VectorMatch] {
        guard dims > 0, topK > 0, query.count == dims else { return [] }
        let bytesPerRow = rowBytes(dims: dims)
        let rowCount = matrix.count / bytesPerRow
        guard rowCount > 0 else { return [] }

        var heap = FixedMinHeap(capacity: topK)
        let blockSize = 1_024
        matrix.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var blockFloats = [Float](repeating: 0, count: dims)
            var row = 0
            while row < rowCount {
                if isCancelled() { break }
                let end = min(row + blockSize, rowCount)
                while row < end {
                    if rowMapping == nil || rowMapping?[Int64(row)] != nil {
                        let pointer = base.advanced(by: row * bytesPerRow)
                        let scale = pointer.loadUnaligned(as: Float.self)
                        let int8 = pointer.advanced(by: scaleByteCount)
                            .assumingMemoryBound(to: Int8.self)
                        vDSP_vflt8(int8, 1, &blockFloats, 1, vDSP_Length(dims))
                        var dot: Float = 0
                        vDSP_dotpr(query, 1, blockFloats, 1, &dot, vDSP_Length(dims))
                        let trackID = rowMapping?[Int64(row)] ?? Int64(row)
                        heap.push(VectorMatch(trackID: trackID, similarity: scale * dot))
                    }
                    row += 1
                }
            }
        }
        return heap.sortedDescending()
    }
}

/// The store façade over the whole-track vector space (§16). Tier A is the
/// brute-force implementation shipping in M2; Tier B (sqlite-vec) is deferred
/// (§16.1, plan §5 2.6) and would implement the same surface.
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
    /// cancellable between scan blocks.
    func search(query: [Float], topK: Int,
                isCancelled: @escaping @Sendable () -> Bool) throws -> [VectorMatch]

    /// Rewrite the matrix without tombstones when tombstones exceed 20% (§16.7).
    func compactIfNeeded() throws

    /// Rebuild `vectors.i8` from `track_embedding` — the source of truth
    /// (§16.5). Deterministic: byte-identical regeneration (NFR-DET-3).
    func rebuildMatrix() throws
}

/// Tier A: append-only `vectors.i8` under `DJDatabase.cachesDirectory` (§13.1),
/// mmap'd read-only scans, `vDSP_vflt8` + `vDSP_dotpr`, fixed-min-heap top-K,
/// cancellable between blocks, tombstone + compaction (§16.2, §16.7).
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

/// A fixed-capacity min-heap over `VectorMatch` by similarity — keeps only the
/// top-K seen so far, O(log K) per push, so a scan never materializes the pool.
private struct FixedMinHeap {
    private var items: [VectorMatch] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func push(_ item: VectorMatch) {
        if items.count < capacity {
            items.append(item)
            siftUp(items.count - 1)
        } else if item.similarity > items[0].similarity {
            items[0] = item
            siftDown(0)
        }
    }

    /// The items in descending similarity order.
    func sortedDescending() -> [VectorMatch] {
        var heap = self
        var out: [VectorMatch] = []
        out.reserveCapacity(heap.items.count)
        while !heap.items.isEmpty {
            out.append(heap.items[0])
            guard heap.items.count > 1 else { break }
            heap.items[0] = heap.items.removeLast()
            heap.siftDown(0)
        }
        return out.reversed()
    }

    private mutating func siftUp(_ start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].similarity < items[parent].similarity else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var parent = start
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < items.count, items[left].similarity < items[smallest].similarity {
                smallest = left
            }
            if right < items.count, items[right].similarity < items[smallest].similarity {
                smallest = right
            }
            guard smallest != parent else { break }
            items.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
