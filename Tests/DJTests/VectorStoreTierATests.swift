import XCTest
import GRDB
import Accelerate

@testable import TonearmDJ

/// Tier A vector store (§16.2, §16.5, §16.7): append-only int8 matrix, mmap
/// scan, tombstones, compaction, byte-identical regeneration (NFR-DET-3).
final class VectorStoreTierATests: XCTestCase {

    private let storeDims = 16

    // MARK: - Helpers

    private func makePool() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("tonearm-dj.sqlite")
        let pool = try DJDatabase.open(at: dbURL)
        return (pool, dir.appendingPathComponent("vectors.i8"))
    }

    private func makeTrack(_ pool: DatabasePool, title: String) throws -> Int64 {
        var track = DJTrack(syncID: UUID().uuidString, title: title,
                            contentHash: "hash-\(title)", sortKey: title,
                            addedAt: Date(), updatedAt: Date())
        try pool.write { db in try track.insert(db) }
        return try XCTUnwrap(track.id)
    }

    private func unitVector(phase: Double, dims: Int = 16) -> [Float] {
        let raw = (0..<dims).map { Float(sin(phase + Double($0) * 0.37)) }
        let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
        return raw.map { $0 / norm }
    }

    private func embedding(for trackID: Int64, vector: [Float],
                           matrixRow: Int? = nil) -> DJTrackEmbedding {
        let (int8, scale) = Quantization.quantize(vector)
        return DJTrackEmbedding(trackID: trackID, int8Vector: int8,
                                scale: Double(scale), matrixRow: matrixRow, version: 1)
    }

    // MARK: - Upsert + scan

    func testUpsertAppendsRowsAndSearches() throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        let a = try makeTrack(pool, title: "alpha")
        let b = try makeTrack(pool, title: "beta")
        let c = try makeTrack(pool, title: "gamma")

        let va = unitVector(phase: 0.1)
        let vb = unitVector(phase: 1.9)
        let vc = unitVector(phase: 3.1)
        try pool.write { db in
            try store.upsert(embedding(for: a, vector: va), db: db)
            try store.upsert(embedding(for: b, vector: vb), db: db)
            try store.upsert(embedding(for: c, vector: vc), db: db)
        }

        XCTAssertEqual(store.rowCount, 3)
        XCTAssertEqual(store.tombstoneCount, 0)

        // Query near `vb` → beta first.
        let results = try store.search(query: vb, topK: 3, isCancelled: { false })
        XCTAssertEqual(results.first?.trackID, b)
        XCTAssertEqual(results.first?.similarity ?? 0, 1.0, accuracy: 0.01)

        let rows = try pool.read { db in
            try DJTrackEmbedding.order(Column("matrixRow")).fetchAll(db)
        }
        XCTAssertEqual(rows.map(\.matrixRow), [0, 1, 2])
    }

    func testTopKRespectsLimit() throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        for i in 0..<5 {
            let track = try makeTrack(pool, title: "t\(i)")
            try pool.write { db in
                try store.upsert(embedding(for: track, vector: unitVector(phase: Double(i))), db: db)
            }
        }
        let results = try store.search(query: unitVector(phase: 2.0), topK: 2,
                                       isCancelled: { false })
        XCTAssertEqual(results.count, 2)
    }

    // MARK: - Tombstone + compaction

    func testRemoveTombstonesMatrixRow() throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        let a = try makeTrack(pool, title: "a")
        let b = try makeTrack(pool, title: "b")
        try pool.write { db in
            try store.upsert(embedding(for: a, vector: unitVector(phase: 0.0)), db: db)
            try store.upsert(embedding(for: b, vector: unitVector(phase: 1.0)), db: db)
        }

        try pool.write { db in try store.remove(trackID: a, db: db) }
        XCTAssertEqual(store.tombstoneCount, 1)

        let tombstoned = try pool.read { db in
            try DJTrackEmbedding.filter(Column("trackID") == a).fetchOne(db)
        }
        XCTAssertNil(tombstoned?.matrixRow, "tombstoned row has matrixRow = NULL")

        // Search no longer returns `a`.
        let results = try store.search(query: unitVector(phase: 0.0), topK: 2,
                                       isCancelled: { false })
        XCTAssertEqual(results.map(\.trackID), [b])
    }

    func testCompactOnlyWhenTombstonesExceed20Percent() throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        var ids: [Int64] = []
        for i in 0..<5 {
            ids.append(try makeTrack(pool, title: "t\(i)"))
        }
        try pool.write { db in
            for (i, id) in ids.enumerated() {
                try store.upsert(embedding(for: id, vector: unitVector(phase: Double(i))), db: db)
            }
        }

        // 1 tombstone of 5 = 20%, exactly at the threshold → no compaction.
        try pool.write { db in try store.remove(trackID: ids[0], db: db) }
        XCTAssertEqual(store.rowCount, 5)
        XCTAssertEqual(store.tombstoneCount, 1)

        // 2 of 5 = 40% > 20% → compacts to 3 live rows.
        try pool.write { db in try store.remove(trackID: ids[1], db: db) }
        try store.compactIfNeeded()
        XCTAssertEqual(store.rowCount, 3)
        XCTAssertEqual(store.tombstoneCount, 0)

        let rows = try pool.read { db in
            try DJTrackEmbedding.filter(Column("matrixRow") != nil)
                .order(Column("matrixRow")).fetchAll(db)
        }
        XCTAssertEqual(rows.map(\.matrixRow), [0, 1, 2])
        XCTAssertEqual(rows.map(\.trackID), [ids[2], ids[3], ids[4]])

        // Search still ranks correctly after compaction.
        let results = try store.search(query: unitVector(phase: 4.0), topK: 3,
                                       isCancelled: { false })
        XCTAssertEqual(results.first?.trackID, ids[4])
    }

    func testRebuildIsByteIdenticalRegeneration() throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        for i in 0..<3 {
            let track = try makeTrack(pool, title: "t\(i)")
            try pool.write { db in
                try store.upsert(embedding(for: track, vector: unitVector(phase: Double(i))), db: db)
            }
        }

        let before = try Data(contentsOf: matrixURL)
        try store.rebuildMatrix()
        let after = try Data(contentsOf: matrixURL)
        XCTAssertEqual(before, after, "rebuild from track_embedding is byte-identical (NFR-DET-3)")

        // A tombstone + compaction must also converge to a rebuild of the live rows.
        let ids = try pool.read { try DJTrack.fetchAll($0).compactMap(\.id) }
        try pool.write { db in
            try store.remove(trackID: ids[0], db: db)
        }
        try store.compactIfNeeded()
        let compacted = try Data(contentsOf: matrixURL)
        try store.rebuildMatrix()
        XCTAssertEqual(try Data(contentsOf: matrixURL), compacted)
    }

    // MARK: - Cancellation

    func testCancelledScanReturnsEarly() throws {
        let (pool, matrixURL) = try makePool()
        defer { try? pool.close() }
        let store = try VectorStoreTierA(pool: pool, dims: storeDims, fileURL: matrixURL)
        let track = try makeTrack(pool, title: "t")
        try pool.write { db in
            try store.upsert(embedding(for: track, vector: unitVector(phase: 0.0)), db: db)
        }
        let cancelled = try store.search(query: unitVector(phase: 0.0), topK: 1,
                                         isCancelled: { true })
        XCTAssertTrue(cancelled.isEmpty, "cancelled scan yields no results")
    }

    // MARK: - Benchmark (FR-SEM-3)

    /// §16.2, plan §5 2.2: a 30k × 512 int8 scan must stay inside a per-row
    /// budget that extrapolates under the 120 ms FR-SEM-3 target. This is the
    /// dev-machine proxy; the real-device number is user-owned (§50.3).
    func testThirtyThousandRowScanStaysInsideBudget() throws {
        let dims = 512
        let rows = 30_000
        let rowBytes = VectorMatrixScanner.rowBytes(dims: dims)
        var data = Data(count: rows * rowBytes)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            for row in 0..<rows {
                let pointer = base.advanced(by: row * rowBytes)
                var scale: Float = 0.9
                withUnsafeBytes(of: &scale) { pointer.copyMemory(from: $0.baseAddress!, byteCount: 4) }
                let int8 = pointer.advanced(by: VectorMatrixScanner.scaleByteCount)
                    .assumingMemoryBound(to: Int8.self)
                for i in 0..<dims {
                    int8[i] = Int8(truncatingIfNeeded: (row + i) & 0x7F)
                }
            }
        }
        let query = unitVector(phase: 0.5, dims: dims)

        let start = DispatchTime.now()
        let results = VectorMatrixScanner.scan(matrix: data, dims: dims, query: query,
                                               rowMapping: nil, topK: 10,
                                               isCancelled: { false })
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9

        XCTAssertEqual(results.count, 10)
        let nsPerRow = elapsed * 1e9 / Double(rows)
        print("TIER-A BENCHMARK: \(rows) x \(dims) scan = \(String(format: "%.1f", elapsed * 1e3)) ms "
            + "(\(String(format: "%.0f", nsPerRow)) ns/row)")
        XCTAssertLessThan(elapsed, 0.120,
                          "30k-row scan took \(elapsed * 1e3) ms, over the 120 ms FR-SEM-3 budget")
    }
}
