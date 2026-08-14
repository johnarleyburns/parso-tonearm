import XCTest
import AVFoundation
import GRDB

@testable import TonearmDJ

/// Commit 5.7 — the stem cache (plan 5.7, §36.4, FR-ENG-3, decision 5):
/// content-addressed four-`.caf` sets under
/// `Stems/<contentHash>/<modelVersion>/`, recorded in `stem_cache` rows
/// written in one transaction. Tests cover content-addressing, version
/// invalidation and eviction — the plan 5.7 list.
final class StemCacheTests: XCTestCase {

    private struct Environment {
        let pool: DatabasePool
        let cache: StemCache
        let root: URL
        let trackID: Int64
    }

    private func makeEnvironment(trackHash: String = "hash-a",
                                 modelVersion: Int = AnalysisVersions.stems) throws -> Environment {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        let root = dir.appendingPathComponent("Stems")

        let now = Date()
        var track = DJTrack(syncID: UUID().uuidString, title: "Cache Me",
                            contentHash: trackHash, sortKey: "cache-me",
                            addedAt: now, updatedAt: now)
        try pool.write { db in try track.insert(db) }
        let trackID = try XCTUnwrap(track.id)

        return Environment(pool: pool,
                           cache: StemCache(pool: pool, root: root, modelVersion: modelVersion),
                           root: root,
                           trackID: trackID)
    }

    /// A deterministic, per-voice-distinct separation (seeded SplitMix64,
    /// NFR-DET-3) so a read-back can prove the *right* voice landed in the
    /// *right* file.
    private func makeSeparation(frames: Int = 4096, seed: UInt64 = 7) -> StemSeparation {
        func voice(_ s: UInt64) -> StemChunk {
            var rng = SplitMix64(seed: s)
            let left = (0..<frames).map { _ in
                Float(Double(rng.next() % 1000) / 1000 - 0.5)
            }
            let right = (0..<frames).map { _ in
                Float(Double(rng.next() % 1000) / 1000 - 0.5)
            }
            return StemChunk(sampleRate: 48_000, left: left, right: right)
        }
        return StemSeparation(sampleRate: 48_000,
                              vocals: voice(seed &+ 1),
                              drums: voice(seed &+ 2),
                              bass: voice(seed &+ 3),
                              other: voice(seed &+ 4))
    }

    private func readAll(_ url: URL) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = Int(file.length)
        guard frameCount > 0, frameCount < Int(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frameCount)) else {
            return ([], [])
        }
        try file.read(into: buffer)
        guard buffer.frameLength > 0, let data = buffer.floatChannelData else { return ([], []) }
        let n = Int(buffer.frameLength)
        return (
            Array(UnsafeBufferPointer(start: data[0], count: n)),
            Array(UnsafeBufferPointer(start: data[1], count: n))
        )
    }

    // MARK: - Content addressing

    func testStoreWritesContentAddressedVersionedFiles() async throws {
        let env = try makeEnvironment(trackHash: "hash-a")
        let separation = makeSeparation()
        try await env.cache.store(separation, trackID: env.trackID, contentHash: "hash-a")

        let base = env.root.appendingPathComponent("hash-a").appendingPathComponent("1")
        for kind in StemKind.allCases {
            let url = base.appendingPathComponent(kind.fileName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(kind.fileName) lives under Stems/<contentHash>/<version>/")
        }

        let row = try env.pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT contentHash, modelVersion, sampleRate, channelCount,
                       totalBytes, pathsJSON FROM stem_cache WHERE trackID = ?
                """, arguments: [env.trackID])
        }
        let record = try XCTUnwrap(row)
        XCTAssertEqual(record["contentHash"] as? String, "hash-a")
        XCTAssertEqual(record["modelVersion"] as? Int64, Int64(AnalysisVersions.stems))
        XCTAssertEqual(record["sampleRate"] as? Int64, 48_000)
        XCTAssertEqual(record["channelCount"] as? Int64, 2)
        XCTAssertGreaterThan(record["totalBytes"] as? Int64 ?? 0, 0)
        let paths = try JSONDecoder().decode(StemCachePaths.self,
                                             from: Data((record["pathsJSON"] as? String ?? "").utf8))
        XCTAssertEqual(paths.vocals, "hash-a/1/vocals.caf")
        XCTAssertEqual(paths.drums, "hash-a/1/drums.caf")
        XCTAssertEqual(paths.bass, "hash-a/1/bass.caf")
        XCTAssertEqual(paths.other, "hash-a/1/other.caf")
    }

    func testTwoHashesNeverShareADirectory() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        let root = dir.appendingPathComponent("Stems")
        let now = Date()
        let a = DJTrack(syncID: UUID().uuidString, title: "A", contentHash: "hash-a",
                        sortKey: "a", addedAt: now, updatedAt: now)
        let b = DJTrack(syncID: UUID().uuidString, title: "B", contentHash: "hash-b",
                        sortKey: "b", addedAt: now, updatedAt: now)
        let aID: Int64 = try await pool.write { db in
            var inserted = a
            try inserted.insert(db)
            return inserted.id!
        }
        let bID: Int64 = try await pool.write { db in
            var inserted = b
            try inserted.insert(db)
            return inserted.id!
        }
        let cache = StemCache(pool: pool, root: root)

        let separation = makeSeparation(frames: 2048)
        try await cache.store(separation, trackID: aID, contentHash: "hash-a")
        try await cache.store(separation, trackID: bID, contentHash: "hash-b")

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("hash-a/1/vocals.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("hash-b/1/vocals.caf").path))
    }

    // MARK: - Round trip

    func testStoreThenLoadRoundTripsTheExactVoices() async throws {
        let env = try makeEnvironment(trackHash: "hash-a")
        let separation = makeSeparation(frames: 9600)
        try await env.cache.store(separation, trackID: env.trackID, contentHash: "hash-a")

        let urls = try await env.cache.load(trackID: env.trackID, modelVersion: AnalysisVersions.stems)
        let loaded = try XCTUnwrap(urls, "a stored set always loads")
        for kind in StemKind.allCases {
            let url = try XCTUnwrap(loaded[kind])
            let audio = try readAll(url)
            let expected = separation.voice(kind)
            XCTAssertEqual(audio.left.count, expected.frameCount,
                           "\(kind.rawValue).caf carries the whole voice (9600 frames)")
            for i in stride(from: 0, to: expected.frameCount, by: 64) {
                XCTAssertEqual(audio.left[i], expected.left[i], accuracy: 1e-7,
                               "\(kind.rawValue).caf left is the exact voice at frame \(i)")
                XCTAssertEqual(audio.right[i], expected.right[i], accuracy: 1e-7,
                               "\(kind.rawValue).caf right is the exact voice at frame \(i)")
            }
        }
        let isCached = try await env.cache.isCached(trackID: env.trackID,
                                                    modelVersion: AnalysisVersions.stems)
        XCTAssertTrue(isCached)
        let bytes = try await env.cache.bytes(onDisk: env.trackID,
                                              modelVersion: AnalysisVersions.stems)
        // The recorded total is the sum of the real on-disk `.caf` sizes — the
        // raw PCM payload plus each file's CAF header/padding, which the §43.6
        // storage budget must count.
        let onDisk: Int64 = loaded.values.reduce(0) { sum, url in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { return sum }
            return sum + size.int64Value
        }
        XCTAssertEqual(bytes, onDisk, "the recorded total is the real on-disk total")
        XCTAssertGreaterThanOrEqual(bytes, 4 * 9600 * 2 * 4,
                                    "at least the raw PCM payload of all four voices")
    }

    func testReStoreIsIdempotentPerVersion() async throws {
        let env = try makeEnvironment(trackHash: "hash-a")
        let first = makeSeparation(frames: 2048, seed: 1)
        let second = makeSeparation(frames: 2048, seed: 2)
        try await env.cache.store(first, trackID: env.trackID, contentHash: "hash-a")
        try await env.cache.store(second, trackID: env.trackID, contentHash: "hash-a")

        let count = try await env.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stem_cache WHERE trackID = ?",
                             arguments: [env.trackID]) ?? 0
        }
        XCTAssertEqual(count, 1, "re-store replaces, never appends (INSERT OR REPLACE)")
        let urls = try await env.cache.load(trackID: env.trackID, modelVersion: AnalysisVersions.stems)
        let loaded = try XCTUnwrap(urls)
        let audio = try readAll(loaded[.vocals]!)
        XCTAssertEqual(audio.left[0], second.voice(.vocals).left[0], accuracy: 1e-7,
                       "the newest separation wins")
    }

    // MARK: - Version invalidation

    func testModelUpgradeInvalidatesCleanly() async throws {
        let env = try makeEnvironment(trackHash: "hash-a", modelVersion: 1)
        try await env.cache.store(makeSeparation(frames: 2048), trackID: env.trackID,
                                  contentHash: "hash-a")

        let v1Cached = try await env.cache.isCached(trackID: env.trackID, modelVersion: 1)
        XCTAssertTrue(v1Cached)
        // A model upgrade is a *new* version: the v1 set is not visible as v2.
        let upgraded = StemCache(pool: env.pool, root: env.root, modelVersion: 2)
        let v2Cached = try await upgraded.isCached(trackID: env.trackID, modelVersion: 2)
        XCTAssertFalse(v2Cached)
        let v2Loaded = try await upgraded.load(trackID: env.trackID, modelVersion: 2)
        XCTAssertNil(v2Loaded)
        let v2Bytes = try await upgraded.bytes(onDisk: env.trackID, modelVersion: 2)
        XCTAssertEqual(v2Bytes, 0)

        // Both version directories coexist; storing v2 leaves v1 untouched.
        try await upgraded.store(makeSeparation(frames: 2048, seed: 9),
                                 trackID: env.trackID, contentHash: "hash-a")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: env.root.appendingPathComponent("hash-a/1/vocals.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: env.root.appendingPathComponent("hash-a/2/vocals.caf").path))
        let v1After = try await env.cache.isCached(trackID: env.trackID, modelVersion: 1)
        XCTAssertTrue(v1After)
        let v2After = try await upgraded.isCached(trackID: env.trackID, modelVersion: 2)
        XCTAssertTrue(v2After)
    }

    // MARK: - Honest absence

    func testLoadReturnsNilWhenFilesAreGone() async throws {
        let env = try makeEnvironment(trackHash: "hash-a")
        try await env.cache.store(makeSeparation(frames: 2048), trackID: env.trackID,
                                  contentHash: "hash-a")
        // The row survives but the files vanish (purge) → honest not-cached.
        try FileManager.default.removeItem(
            at: env.root.appendingPathComponent("hash-a"))
        let isCached = try await env.cache.isCached(trackID: env.trackID,
                                                    modelVersion: AnalysisVersions.stems)
        XCTAssertFalse(isCached)
        let loaded = try await env.cache.load(trackID: env.trackID,
                                              modelVersion: AnalysisVersions.stems)
        XCTAssertNil(loaded,
                     "a row without files is absence, never a corrupt result (FR-SEM-6)")
    }

    // MARK: - Eviction

    func testEvictRemovesRowAndFiles() async throws {
        let env = try makeEnvironment(trackHash: "hash-a")
        try await env.cache.store(makeSeparation(frames: 2048), trackID: env.trackID,
                                  contentHash: "hash-a")
        let cachedBefore = try await env.cache.isCached(trackID: env.trackID,
                                                        modelVersion: AnalysisVersions.stems)
        XCTAssertTrue(cachedBefore)

        try await env.cache.evict(trackID: env.trackID, modelVersion: AnalysisVersions.stems)

        let cachedAfter = try await env.cache.isCached(trackID: env.trackID,
                                                       modelVersion: AnalysisVersions.stems)
        XCTAssertFalse(cachedAfter)
        let dir = env.root.appendingPathComponent("hash-a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "eviction removes the on-disk set when no row references it")
        let rowCount = try await env.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stem_cache WHERE trackID = ?",
                             arguments: [env.trackID]) ?? 0
        }
        XCTAssertEqual(rowCount, 0)
    }

    func testEvictOfTrackWithNoCacheIsANoOp() async throws {
        let env = try makeEnvironment(trackHash: "hash-a")
        try await env.cache.evict(trackID: env.trackID, modelVersion: AnalysisVersions.stems)
        let cached = try await env.cache.isCached(trackID: env.trackID,
                                                  modelVersion: AnalysisVersions.stems)
        XCTAssertFalse(cached)
    }

    func testEvictingOneTrackKeepsASharedDirectoriesOtherTrack() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        let root = dir.appendingPathComponent("Stems")
        let now = Date()
        let a = DJTrack(syncID: UUID().uuidString, title: "A", contentHash: "shared",
                        sortKey: "a", addedAt: now, updatedAt: now)
        let b = DJTrack(syncID: UUID().uuidString, title: "B", contentHash: "shared",
                        sortKey: "b", addedAt: now, updatedAt: now)
        let aID: Int64 = try await pool.write { db in
            var inserted = a
            try inserted.insert(db)
            return inserted.id!
        }
        let bID: Int64 = try await pool.write { db in
            var inserted = b
            try inserted.insert(db)
            return inserted.id!
        }
        let cache = StemCache(pool: pool, root: root)

        let separation = makeSeparation(frames: 2048)
        try await cache.store(separation, trackID: aID, contentHash: "shared")
        try await cache.store(separation, trackID: bID, contentHash: "shared")

        try await cache.evict(trackID: aID, modelVersion: AnalysisVersions.stems)

        let aCached = try await cache.isCached(trackID: aID, modelVersion: AnalysisVersions.stems)
        XCTAssertFalse(aCached)
        let bCached = try await cache.isCached(trackID: bID, modelVersion: AnalysisVersions.stems)
        XCTAssertTrue(bCached, "track B still references the shared directory")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("shared/1/vocals.caf").path),
            "the shared files survive eviction of one referencer")

        try await cache.evict(trackID: bID, modelVersion: AnalysisVersions.stems)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("shared").path),
            "the last referencer's eviction removes the directory")
    }
}
