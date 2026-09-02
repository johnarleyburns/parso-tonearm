import XCTest
import GRDB

@testable import TonearmDJ

/// Commit 5.9 — the §36.3 stem lane (plan 5.9, decision 2, FR-ANL-9,
/// FR-ANL-2, §43.7): crate-scoped separation that respects the storage budget
/// (evicting least-recently-performed crates first), pauses while a performance
/// is live, abandons when the `.stems` governor lane is shed, and marks each
/// track `ready` only when its voices are safely in the cache. Driven against a
/// deterministic fake model (plan decision 1) and real short WAVs, so the
/// decode → separate → cache → ready path is exercised end to end off-device.
final class StemServiceTests: XCTestCase {

    // MARK: - Fakes

    /// Deterministic passthrough model: every voice is the chunk's stereo input.
    private struct PassthroughStemModel: StemModelProviding {
        var version: Int = AnalysisVersions.stems
        var available: Bool = true
        func isAvailable() async -> Bool { available }
        func separate(chunk: StemChunk) async throws -> StemSeparation? {
            guard available else { return nil }
            return StemSeparation(sampleRate: chunk.sampleRate,
                                  vocals: chunk, drums: chunk,
                                  bass: chunk, other: chunk)
        }
    }

    /// A lock-protected box for values captured by `@Sendable` callbacks.
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Value
        init(_ value: Value) { _value = value }
        var value: Value { lock.lock(); defer { lock.unlock() }; return _value }
        func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; _value = value }
    }

    /// A lock-protected gate the tests can flip mid-run (the §36.3 "abandons
    /// the instant thermalState reaches `.serious`" case). NSLock boxed state —
    /// the same documented pattern as `AnalysisCoordinator.Counter`.
    private final class LockedGate: @unchecked Sendable {
        private let lock = NSLock()
        private var _allows: Bool
        init(_ allows: Bool) { _allows = allows }
        var allows: Bool { lock.lock(); defer { lock.unlock() }; return _allows }
        func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; _allows = value }
    }

    // MARK: - Helpers

    private struct Environment {
        let pool: DatabasePool
        let dir: URL
        let model: PassthroughStemModel
    }

    private func makeEnvironment() throws -> Environment {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        return Environment(pool: pool, dir: dir, model: PassthroughStemModel())
    }

    /// Writes a 48 kHz mono 16-bit PCM WAV from Float32 samples.
    private func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        var size = UInt32(36 + samples.count * 2)
        data.append(Data(bytes: &size, count: 4))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        var fmtSize = UInt32(16); data.append(Data(bytes: &fmtSize, count: 4))
        var pcm: UInt16 = 1; data.append(Data(bytes: &pcm, count: 2))
        var mono: UInt16 = 1; data.append(Data(bytes: &mono, count: 2))
        var sampleRate: UInt32 = 48_000; data.append(Data(bytes: &sampleRate, count: 4))
        var byteRate = sampleRate * 2; data.append(Data(bytes: &byteRate, count: 4))
        var align: UInt16 = 2; data.append(Data(bytes: &align, count: 2))
        var bits: UInt16 = 16; data.append(Data(bytes: &bits, count: 2))
        data.append(contentsOf: Array("data".utf8))
        var dataSize = UInt32(samples.count * 2); data.append(Data(bytes: &dataSize, count: 4))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var le = Int16((clamped * Float(Int16.max)).rounded()).littleEndian
            data.append(Data(bytes: &le, count: 2))
        }
        try data.write(to: url)
    }

    /// Seeds `count` tracks (each backed by a real 1–2 s WAV) and a gig crate
    /// over them, all `pending`. Returns the crate id and the track IDs in
    /// position order.
    private func seedCrate(_ env: Environment, trackCount: Int,
                           seconds: Double = 1) async throws -> (crateID: Int64, trackIDs: [Int64], urls: [Int64: URL]) {
        let now = Date()
        var trackIDs: [Int64] = []
        var urls: [Int64: URL] = [:]
        for i in 0..<trackCount {
            let title = "track-\(i)"
            let url = env.dir.appendingPathComponent("\(title).wav")
            try writeWAV(SyntheticAudio.clickTrack(bpm: 120, seconds: seconds), to: url)
            let trackID = try await env.pool.write { db in
                var track = DJTrack(syncID: UUID().uuidString, title: title,
                                    contentHash: "hash-\(title)", sortKey: title,
                                    addedAt: now, updatedAt: now)
                try track.insert(db)
                return track.id!
            }
            trackIDs.append(trackID)
            urls[trackID] = url
        }

        // Immutable snapshot so the @Sendable write closure captures a let.
        let trackIDsSnapshot = trackIDs

        let crateID: Int64 = try await env.pool.write { db in
            var crate = GigCrate(syncID: UUID().uuidString, name: "Crate",
                                 storageBudgetBytes: 4_000_000_000, createdAt: now)
            try crate.insert(db)
            let id = crate.id!
            let ids = trackIDsSnapshot
            for (position, trackID) in ids.enumerated() {
                var row = GigCrateTrack(gigCrateID: id, trackID: trackID,
                                        position: position + 1)
                try row.insert(db)
            }
            return id
        }
        return (crateID, trackIDs, urls)
    }

    private func makeService(_ env: Environment,
                             assetURL: @escaping @Sendable (Int64, Database) throws -> URL?,
                             gate: LockedGate? = nil,
                             onProgress: @escaping @Sendable (StemProgress) -> Void = { _ in },
                             onStemsReady: @escaping @Sendable (Int64) -> Void = { _ in },
                             model: StemModelProviding? = nil) -> StemService {
        let cacheRoot = env.dir.appendingPathComponent("Stems")
        let cache = StemCache(pool: env.pool, root: cacheRoot)
        let separator = StemSeparator(model: model ?? env.model)
        let gateValue = gate
        return StemService(pool: env.pool,
                           separator: separator,
                           cache: cache,
                           repository: GigCrateRepository(pool: env.pool),
                           assetURL: assetURL,
                           governorAllowsRun: { gateValue?.allows ?? true },
                           onProgress: onProgress,
                           onStemsReady: onStemsReady)
    }

    private func stemsState(_ env: Environment, crateID: Int64,
                            trackID: Int64) throws -> String {
        try env.pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT stemsState FROM gig_crate_track
                WHERE gigCrateID = ? AND trackID = ?
                """, arguments: [crateID, trackID]) ?? "missing"
        }
    }

    private func stemCacheCount(_ env: Environment) throws -> Int {
        try env.pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stem_cache") ?? 0
        }
    }

    // MARK: - The lane

    func testCrateLaneSeparatesPendingTracksToReady() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let (crateID, trackIDs, urls) = try await seedCrate(env, trackCount: 2)
        let progress = LockedBox<StemProgress?>(nil)
        let service = makeService(env, assetURL: { id, _ in urls[id] },
                                  onProgress: { progress.set($0) })

        await service.runCrateLane(crateID: crateID, budget: 12_000_000_000)

        for trackID in trackIDs {
            XCTAssertEqual(try stemsState(env, crateID: crateID, trackID: trackID),
                           "ready", "track \(trackID) separates to ready")
        }
        XCTAssertEqual(try stemCacheCount(env), 2,
                       "every ready track has a cached stem set")
        let readyCount = try await env.pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM gig_crate_track
                WHERE gigCrateID = ? AND stemsState = 'ready'
                """, arguments: [crateID]) ?? 0
        }
        XCTAssertEqual(readyCount, 2)
        let stemsBytes = try await env.pool.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT COALESCE(SUM(stemsBytes), 0) FROM gig_crate_track WHERE gigCrateID = ?
                """, arguments: [crateID]) ?? 0
        }
        XCTAssertGreaterThan(stemsBytes, 0, "the roll-up records the on-disk bytes")
        let trackStemState = try await env.pool.read { db in
            try String.fetchOne(db, sql: "SELECT stemState FROM track WHERE id = ?",
                                arguments: [trackIDs[0]]) ?? ""
        }
        XCTAssertEqual(trackStemState, "ready", "the track roll-up is stamped too")
        XCTAssertEqual(progress.value?.completed, 2, "the lane reports completion")
    }

    func testRerunIsANoOpForReadyTracks() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let (crateID, _, urls) = try await seedCrate(env, trackCount: 2)
        let service = makeService(env, assetURL: { id, _ in urls[id] })

        await service.runCrateLane(crateID: crateID, budget: 12_000_000_000)
        await service.runCrateLane(crateID: crateID, budget: 12_000_000_000)

        XCTAssertEqual(try stemCacheCount(env), 2,
                       "re-running never re-separates a ready track")
        let remaining = try await service.reconcileCount(crateID: crateID)
        XCTAssertEqual(remaining, 0)
    }

    func testPerformingFencePausesTheLane() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let (crateID, trackIDs, urls) = try await seedCrate(env, trackCount: 2)
        let service = makeService(env, assetURL: { id, _ in urls[id] })
        await service.setPerforming(true)

        await service.runCrateLane(crateID: crateID, budget: 12_000_000_000)

        for trackID in trackIDs {
            XCTAssertEqual(try stemsState(env, crateID: crateID, trackID: trackID),
                           "pending",
                           "a live performance pins the lane to paused (FR-ANL-2)")
        }
        XCTAssertEqual(try stemCacheCount(env), 0)
    }

    func testGovernorGateAbandonsTheLane() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let (crateID, trackIDs, urls) = try await seedCrate(env, trackCount: 2)
        // Shed from the start — §43.7's `.stems` lane paused at `.serious`.
        let service = makeService(env, assetURL: { id, _ in urls[id] },
                                  gate: LockedGate(false))

        await service.runCrateLane(crateID: crateID, budget: 12_000_000_000)

        for trackID in trackIDs {
            XCTAssertEqual(try stemsState(env, crateID: crateID, trackID: trackID),
                           "pending", "the lane abandons when the lane is shed")
        }
    }

    func testModelAbsenceLeavesTracksPendingNotFailed() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let (crateID, trackIDs, urls) = try await seedCrate(env, trackCount: 1)
        // FR-SEM-6 absence: the model is not available → honest absence, never
        // a failed state and never a partial cache.
        let service = makeService(env,
                                  assetURL: { id, _ in urls[id] },
                                  model: PassthroughStemModel(available: false))

        await service.runCrateLane(crateID: crateID, budget: 12_000_000_000)

        XCTAssertEqual(try stemsState(env, crateID: crateID, trackID: trackIDs[0]),
                       "pending", "absence is a value, not a failure")
        XCTAssertEqual(try stemCacheCount(env), 0)
    }

    func testMidRunGovernorFlipAbandonsTheRemainingTracks() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let (crateID, trackIDs, urls) = try await seedCrate(env, trackCount: 2)
        let gate = LockedGate(true)
        // The gate flips to false the instant the first track's stems land —
        // the §36.3 "abandons work the instant thermalState reaches `.serious`".
        let service = makeService(env, assetURL: { id, _ in urls[id] },
                                  gate: gate,
                                  onStemsReady: { _ in gate.set(false) })

        await service.runCrateLane(crateID: crateID, budget: 12_000_000_000)

        XCTAssertEqual(try stemsState(env, crateID: crateID, trackID: trackIDs[0]),
                       "ready", "the in-flight track finished")
        XCTAssertEqual(try stemsState(env, crateID: crateID, trackID: trackIDs[1]),
                       "pending", "the rest stay pending, never half-separated")
        XCTAssertEqual(try stemCacheCount(env), 1)
    }

    // MARK: - Budget eviction (FR-ANL-9, AT-STEM-*)

    func testLaneEvictsLRUCrateToMakeRoom() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        // Crate A: performed long ago, stems fully prepared (real cache rows).
        let (crateA, trackA, urlsA) = try await seedCrate(env, trackCount: 1, seconds: 2)
        try await env.pool.write { db in
            try db.execute(sql: "UPDATE gig_crate SET lastPerformedAt = ? WHERE id = ?",
                           arguments: [Date(timeIntervalSinceNow: -48 * 3600), crateA])
        }
        let prepareA = makeService(env, assetURL: { id, _ in urlsA[id] })
        await prepareA.runCrateLane(crateID: crateA, budget: 12_000_000_000)
        XCTAssertEqual(try stemsState(env, crateID: crateA, trackID: trackA[0]), "ready")
        let crateABytes = try await env.pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT stemsBytes FROM gig_crate_track WHERE gigCrateID = ?",
                               arguments: [crateA]) ?? 0
        }
        XCTAssertGreaterThan(crateABytes, 0)

        // Crate B: never performed, needs room. Budget = exactly the ~13 MB
        // projection of B's single pending track — it only fits if A's stems
        // are evicted first (A's bytes push the projection over the line).
        let (crateB, trackB, urlsB) = try await seedCrate(env, trackCount: 1)
        let budget = StorageBudgetService.estimatedStemsBytesPerTrack

        let preview = try await prepareA.planPreparation(crateID: crateB, budget: budget)
        XCTAssertTrue(preview.needsEviction, "the preview names the eviction")
        XCTAssertEqual(preview.evictions.map(\.crateID), [crateA],
                       "the least-recently-performed crate is evicted first")

        let lane = makeService(env, assetURL: { id, _ in urlsB[id] })
        await lane.runCrateLane(crateID: crateB, budget: budget)

        XCTAssertEqual(try stemsState(env, crateID: crateA, trackID: trackA[0]),
                       "evicted", "A's stems were evicted to make room")
        XCTAssertEqual(try stemsState(env, crateID: crateB, trackID: trackB[0]),
                       "ready", "B prepared inside the reclaimed budget")
        XCTAssertEqual(try stemCacheCount(env), 1, "only B's set remains on disk")
    }

    func testLaneRefusesWhenEvenEvictionCannotFit() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let (crateID, trackIDs, urls) = try await seedCrate(env, trackCount: 2)
        // A budget that cannot hold even one ~13 MB projected track.
        let service = makeService(env, assetURL: { id, _ in urls[id] })
        await service.runCrateLane(crateID: crateID, budget: 1_000_000)

        for trackID in trackIDs {
            XCTAssertEqual(try stemsState(env, crateID: crateID, trackID: trackID),
                           "pending", "nothing separates when the budget cannot hold the crate")
        }
        XCTAssertEqual(try stemCacheCount(env), 0)
    }

    // MARK: - On-demand separation (§36.5)

    func testOnDemandSeparationHonorsTheFenceAndCaches() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let (crateID, trackIDs, urls) = try await seedCrate(env, trackCount: 1)
        let service = makeService(env, assetURL: { id, _ in urls[id] })

        // A live performance refuses on-demand separation (best-effort, §36.5).
        await service.setPerforming(true)
        let refused = await service.separateOnDemand(trackID: trackIDs[0])
        XCTAssertNil(refused)

        // Normally it separates and caches — best-effort never blocks the deck.
        await service.setPerforming(false)
        let separated = await service.separateOnDemand(trackID: trackIDs[0])
        XCTAssertNotNil(separated)
        XCTAssertEqual(try stemCacheCount(env), 1)
        _ = crateID
    }

    // MARK: - Progress stream

    func testProgressStreamEmitsLaneSteps() async throws {
        let env = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: env.dir) }
        let (crateID, _, urls) = try await seedCrate(env, trackCount: 2)
        let service = makeService(env, assetURL: { id, _ in urls[id] })

        let stream = await service.observeProgress()
        let collector = Task { () -> [StemProgress] in
            var steps: [StemProgress] = []
            for await progress in stream {
                steps.append(progress)
                if progress.completed >= 2 { break }
            }
            return steps
        }
        await service.runCrateLane(crateID: crateID, budget: 12_000_000_000)
        let steps = await collector.value
        XCTAssertFalse(steps.isEmpty)
        XCTAssertGreaterThanOrEqual(steps.last?.completed ?? 0, 2,
                                    "the stream reports the lane's completion")
    }
}
