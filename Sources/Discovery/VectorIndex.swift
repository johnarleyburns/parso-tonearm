#if !os(watchOS)
import Foundation
import GRDB
import ParsoAudioNeural
import TonearmCore

/// The single actor that owns the derived whole-catalog vector cache (plan §8).
///
/// `discovery_embedding` rows are authoritative; this cache is disposable
/// derived state. The actor serializes every mutation and publication: a
/// snapshot is an immutable, generation-stamped value built off-main and then
/// atomically published for scans. A missing / truncated / stale / purged
/// cache file is rebuilt from the embedding rows — a vanished cache never
/// marks a job incomplete (plan §8).
///
/// "Mixed pipeline versions not queried together" (plan §6/§9) is enforced
/// here: the snapshot adopts the model / preprocessing / sampling versions of
/// the most recently completed embedding and includes ONLY rows that match all
/// three plus its dimension count. Older-pipeline rows are simply absent from
/// the scan set.
public actor VectorIndex {
    /// An immutable, generation-stamped view of the eligible vector matrix.
    public struct Snapshot: Sendable {
        /// Monotonic per-process build number. Recorded by a search so a
        /// stale response can be detected (plan §8/§9).
        public let generation: Int64
        /// Content signature of the `discovery_embedding` rows this snapshot
        /// was built from. When the live signature differs, the snapshot is
        /// stale and a rebuild is required before use.
        public let signature: Signature
        public let dimensions: Int
        public let modelVersion: Int
        public let preprocessingVersion: Int
        public let samplingVersion: Int
        /// `rowCount` rows of `Float32 scale (LE) + Int8[dimensions]` — the
        /// layout `ParsoAudioNeural.VectorMatrixScanner` and
        /// `VectorQuantization.dequantize` consume.
        public let matrix: Data
        /// Parallel to the matrix rows: physical row → core `track.id`.
        public let trackIDByRow: [Int64]

        public var rowCount: Int { trackIDByRow.count }

        public func dequantizedRow(_ row: Int) -> [Float] {
            let stride = VectorIndex.rowBytes(dimensions: dimensions)
            let start = row * stride
            let scale = matrix.withUnsafeBytes { raw -> Float in
                raw.loadUnaligned(fromByteOffset: start, as: Float.self)
            }
            let int8 = matrix.withUnsafeBytes { raw -> [Int8] in
                let base = raw.baseAddress!.advanced(by: start + VectorIndex.scaleBytes)
                return Array(UnsafeBufferPointer(
                    start: base.assumingMemoryBound(to: Int8.self), count: dimensions))
            }
            return VectorQuantization.dequantize(int8, scale: scale)
        }
    }

    /// A cheap fingerprint of the authoritative embedding rows: if any of
    /// these three change, the snapshot is stale. Row inserts change `count`
    /// and `sumTrackID`; a re-embed at a new revision changes
    /// `maxCompletedAt`; a delete (FK cascade) drops `count`/`sumTrackID`.
    public struct Signature: Equatable, Sendable {
        public let count: Int
        public let sumTrackID: Int64
        public let maxCompletedAt: String
    }

    public enum IndexError: Error, Equatable {
        case cacheValidationFailed(String)
    }

    static let scaleBytes = 4
    static func rowBytes(dimensions: Int) -> Int { scaleBytes + dimensions }
    private static let magic = Array("TADISCV1".utf8)
    private static let headerBytes = 128

    private let writer: any DatabaseWriter
    private let cacheURL: URL
    private var published: Snapshot?
    private var generationCounter: Int64 = 0

    public init(writer: any DatabaseWriter, cacheURL: URL = DiscoveryCaches.vectorCacheURL()) {
        self.writer = writer
        self.cacheURL = cacheURL
    }

    // MARK: - Public API

    /// The current consistent snapshot. Rebuilds (and republishes the cache
    /// file) if the in-memory snapshot is absent or its signature no longer
    /// matches the live embedding rows — including the crash-between-commit-
    /// and-publication case, where the on-disk cache is stale but the DB is
    /// ahead (plan §8: "reconcile generation and rebuild before using stale
    /// snapshots").
    public func currentSnapshot() throws -> Snapshot {
        let live = try liveSignature()

        if let published, published.signature == live {
            return published
        }
        if let loaded = try? loadCache(), loaded.signature == live {
            published = loaded
            return loaded
        }
        let rebuilt = try rebuild(signature: live)
        published = rebuilt
        return rebuilt
    }

    /// Force a rebuild from the authoritative rows regardless of the current
    /// cache state — used when a caller knows the derived file is gone or
    /// corrupt, and by the recovery tests.
    @discardableResult
    public func rebuildFromEmbeddings() throws -> Snapshot {
        let rebuilt = try rebuild(signature: try liveSignature())
        published = rebuilt
        return rebuilt
    }

    /// Drop the in-memory snapshot (not the file) — the next `currentSnapshot`
    /// re-reads/rebuilds. Bounds retained snapshots (plan §8: "release them
    /// when queries finish").
    public func releasePublishedSnapshot() {
        published = nil
    }

    /// Test/diagnostic hook: the raw bytes currently on disk, if any.
    public func cacheFileByteCount() -> Int? {
        (try? Data(contentsOf: cacheURL))?.count
    }

    // MARK: - Signature

    private func liveSignature() throws -> Signature {
        try writer.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) AS c,
                           COALESCE(SUM(trackId), 0) AS s,
                           COALESCE(MAX(completedAt), '') AS m
                    FROM discovery_embedding
                    """)
            return Signature(
                count: row?["c"] ?? 0,
                sumTrackID: row?["s"] ?? 0,
                maxCompletedAt: row?["m"] ?? "")
        }
    }

    // MARK: - Rebuild

    private func rebuild(signature: Signature) throws -> Snapshot {
        generationCounter += 1
        let generation = generationCounter

        struct Head {
            let dims: Int
            let model: Int
            let preprocessing: Int
            let sampling: Int
        }

        let (head, rows): (Head?, [DiscoveryEmbedding]) = try writer.read { db in
            // The most recently completed embedding defines the "current"
            // pipeline; every older-version row is excluded from the scan set.
            guard let newest = try DiscoveryEmbedding
                .order(Column("completedAt").desc, Column("trackId").desc)
                .fetchOne(db)
            else { return (nil, []) }
            let head = Head(
                dims: newest.dimensions,
                model: newest.modelVersion,
                preprocessing: newest.preprocessingVersion,
                sampling: newest.samplingVersion)
            let matching = try DiscoveryEmbedding
                .filter(Column("modelVersion") == head.model)
                .filter(Column("preprocessingVersion") == head.preprocessing)
                .filter(Column("samplingVersion") == head.sampling)
                .filter(Column("dimensions") == head.dims)
                .order(Column("trackId").asc)
                .fetchAll(db)
            return (head, matching)
        }

        guard let head else {
            return Snapshot(
                generation: generation, signature: signature, dimensions: 0,
                modelVersion: 0, preprocessingVersion: 0, samplingVersion: 0,
                matrix: Data(), trackIDByRow: [])
        }

        let stride = Self.rowBytes(dimensions: head.dims)
        var matrix = Data(capacity: rows.count * stride)
        var ids: [Int64] = []
        ids.reserveCapacity(rows.count)

        for row in rows {
            // Validate length, finite scale, nonzero payload (plan §4/§8).
            guard row.quantizedVector.count == head.dims, row.scale.isFinite else { continue }
            var scale = Float(row.scale)
            withUnsafeBytes(of: &scale) { matrix.append(contentsOf: $0) }
            matrix.append(row.quantizedVector)
            ids.append(row.trackId)
        }

        let snapshot = Snapshot(
            generation: generation,
            signature: signature,
            dimensions: head.dims,
            modelVersion: head.model,
            preprocessingVersion: head.preprocessing,
            samplingVersion: head.sampling,
            matrix: matrix,
            trackIDByRow: ids)

        try writeCache(snapshot)
        return snapshot
    }

    // MARK: - Cache file I/O

    private func writeCache(_ snapshot: Snapshot) throws {
        var data = Data()
        data.append(contentsOf: Self.magic)
        appendU32(&data, 1)  // format version
        appendU32(&data, UInt32(snapshot.dimensions))
        appendI32(&data, Int32(snapshot.modelVersion))
        appendI32(&data, Int32(snapshot.preprocessingVersion))
        appendI32(&data, Int32(snapshot.samplingVersion))
        appendU64(&data, UInt64(snapshot.rowCount))
        appendI64(&data, Int64(snapshot.signature.count))
        appendI64(&data, snapshot.signature.sumTrackID)
        let sigBytes = Array(snapshot.signature.maxCompletedAt.utf8).prefix(32)
        var sigField = Array(sigBytes)
        sigField.append(contentsOf: Array(repeating: 0, count: 32 - sigField.count))
        data.append(contentsOf: sigField)
        // Pad the header to a fixed size.
        if data.count < Self.headerBytes {
            data.append(contentsOf: Array(repeating: 0, count: Self.headerBytes - data.count))
        }
        data.append(snapshot.matrix)
        for id in snapshot.trackIDByRow { appendI64(&data, id) }

        // `Data.write(options: .atomic)` is itself temp-file + atomic rename.
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cacheURL, options: .atomic)

        // Validate what actually landed (plan §8: "validate expected byte
        // length/version/dimensions").
        let expected =
            Self.headerBytes + snapshot.rowCount * Self.rowBytes(dimensions: snapshot.dimensions)
            + snapshot.rowCount * 8
        let actual = (try? Data(contentsOf: cacheURL))?.count ?? -1
        guard actual == expected else {
            try? FileManager.default.removeItem(at: cacheURL)
            throw IndexError.cacheValidationFailed(
                "wrote \(actual) bytes, expected \(expected)")
        }
    }

    private func loadCache() throws -> Snapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        guard data.count >= Self.headerBytes else {
            throw IndexError.cacheValidationFailed("file shorter than header")
        }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<8]) == Self.magic else {
            throw IndexError.cacheValidationFailed("bad magic")
        }
        var cursor = 8
        let format = readU32(bytes, &cursor)
        guard format == 1 else { throw IndexError.cacheValidationFailed("format \(format)") }
        let dims = Int(readU32(bytes, &cursor))
        let model = Int(readI32(bytes, &cursor))
        let preprocessing = Int(readI32(bytes, &cursor))
        let sampling = Int(readI32(bytes, &cursor))
        let rowCount = Int(readU64(bytes, &cursor))
        let sigCount = Int(readI64(bytes, &cursor))
        let sigSum = readI64(bytes, &cursor)
        let sigMaxRaw = Array(bytes[cursor..<cursor + 32])
        let sigMax = String(decoding: sigMaxRaw.prefix { $0 != 0 }, as: UTF8.self)

        let stride = Self.rowBytes(dimensions: dims)
        let expected = Self.headerBytes + rowCount * stride + rowCount * 8
        guard dims > 0, rowCount >= 0, data.count == expected else {
            throw IndexError.cacheValidationFailed(
                "length \(data.count) != expected \(expected) (dims \(dims), rows \(rowCount))")
        }

        let matrixStart = Self.headerBytes
        let matrixEnd = matrixStart + rowCount * stride
        let matrix = data.subdata(in: matrixStart..<matrixEnd)
        var ids: [Int64] = []
        ids.reserveCapacity(rowCount)
        var idCursor = matrixEnd
        for _ in 0..<rowCount {
            ids.append(readI64(bytes, &idCursor))
        }

        // A loaded snapshot re-uses the file's generation as 0 until adopted;
        // bump the counter so an adopted-from-disk snapshot still has a
        // process-monotonic generation.
        generationCounter += 1
        return Snapshot(
            generation: generationCounter,
            signature: Signature(count: sigCount, sumTrackID: sigSum, maxCompletedAt: sigMax),
            dimensions: dims,
            modelVersion: model,
            preprocessingVersion: preprocessing,
            samplingVersion: sampling,
            matrix: matrix,
            trackIDByRow: ids)
    }

    // MARK: - Little-endian helpers

    private func appendU32(_ d: inout Data, _ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    private func appendI32(_ d: inout Data, _ v: Int32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    private func appendU64(_ d: inout Data, _ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    private func appendI64(_ d: inout Data, _ v: Int64) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

    private func readU32(_ b: [UInt8], _ c: inout Int) -> UInt32 {
        defer { c += 4 }
        return b[c..<c + 4].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private func readI32(_ b: [UInt8], _ c: inout Int) -> Int32 { Int32(bitPattern: readU32(b, &c)) }
    private func readU64(_ b: [UInt8], _ c: inout Int) -> UInt64 {
        defer { c += 8 }
        return b[c..<c + 8].reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    private func readI64(_ b: [UInt8], _ c: inout Int) -> Int64 { Int64(bitPattern: readU64(b, &c)) }
}
#endif
