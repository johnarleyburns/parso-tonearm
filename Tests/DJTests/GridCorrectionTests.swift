import XCTest
import GRDB

@testable import TonearmCore
@testable import TonearmDJ

/// Commit 4.12 — Track Prep grid corrections (plan 4.12, FR-PREP-5, §23.3,
/// AT-GRID-*). The §23.3 contract in three layers:
///
/// - **Pure:** `GridReplay` replays the correction log over the detected grid
///   deterministically; `TempoTapper` collapses taps to a BPM.
/// - **DB:** a correction appended through `GridCorrectionRepository` overrides
///   without mutating the immutable analysis (`beat_grid` is untouched),
///   **persists**, and feeds the authoritative `DeckGrid` a deck would load.
/// - **VM:** `TrackPrepModel` gates the tools by `.preparation` at the intent
///   boundary (App. T.3) and forwards through a fake repository.
@MainActor
final class GridCorrectionTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - GridReplay (pure, §23.3)

    func testReplayAppliesEveryOpDeterministically() {
        let base = DeckGrid(referenceSample: 0, bpm: 128, beatsPerBar: 4, sampleRate: 48_000)

        let corrections = [
            correction(op: .setDownbeat, valueInt: 24_000),
            correction(op: .doubleBPM),
            correction(op: .nudge, valueInt: 1000),
            correction(op: .setBPM, valueDouble: 140),
            correction(op: .halveBPM),
            correction(op: .shift, valueInt: -500)
        ]
        let grid = GridReplay.authoritativeGrid(base: base, corrections: corrections)

        XCTAssertEqual(grid.referenceSample, 24_000 + 1000 - 500, accuracy: 1e-9,
                       "setDownbeat sets beat 0; the nudge and shift add on top, in log order")
        XCTAssertEqual(grid.bpm, 70, accuracy: 1e-9, "double ×2, then setBPM, then halve ÷2")
        XCTAssertEqual(grid.beatsPerBar, 4, "replay never touches the bar structure")
        XCTAssertEqual(grid.sampleRate, 48_000)
    }

    func testReplayOrderingLastAbsoluteOpWins() {
        let base = DeckGrid(referenceSample: 0, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        // Two absolute ops: the later one wins. The nudge between them applies
        // but is itself superseded by the later setDownbeat — replay is a
        // deterministic log, and the newest absolute intent is authoritative.
        let corrections = [
            correction(op: .setDownbeat, valueInt: 12_000, appliedAt: fixedDate.addingTimeInterval(1)),
            correction(op: .nudge, valueInt: 100, appliedAt: fixedDate.addingTimeInterval(2)),
            correction(op: .setDownbeat, valueInt: 48_000, appliedAt: fixedDate.addingTimeInterval(3))
        ]
        let grid = GridReplay.authoritativeGrid(base: base, corrections: corrections)
        XCTAssertEqual(grid.referenceSample, 48_000, accuracy: 1e-9,
                       "the later setDownbeat is authoritative; the earlier nudge is superseded")
    }

    func testReplayIsDeterministicRegardlessOfArrayOrder() {
        let base = DeckGrid(referenceSample: 0, bpm: 120, beatsPerBar: 4, sampleRate: 48_000)
        let a = correction(op: .setDownbeat, valueInt: 10_000, appliedAt: fixedDate.addingTimeInterval(2))
        let b = correction(op: .nudge, valueInt: 500, appliedAt: fixedDate.addingTimeInterval(1))

        let forward = GridReplay.authoritativeGrid(base: base, corrections: [a, b])
        let reversed = GridReplay.authoritativeGrid(base: base, corrections: [b, a])
        XCTAssertEqual(forward.referenceSample, reversed.referenceSample,
                       "replay sorts by appliedAt (then id), so the input order cannot matter (NFR-DET)")
    }

    func testReplaySkipsMalformedCorrections() {
        let base = DeckGrid(referenceSample: 0, bpm: 128, beatsPerBar: 4, sampleRate: 48_000)
        let malformed = [
            GridCorrection(syncID: UUID().uuidString, trackID: 1, op: "notAnOp",
                           appliedAt: fixedDate),
            correction(op: .setBPM) // no value — skipped, keeps the detected grid
        ]
        let grid = GridReplay.authoritativeGrid(base: base, corrections: malformed)
        XCTAssertEqual(grid.referenceSample, 0, accuracy: 1e-9)
        XCTAssertEqual(grid.bpm, 128, accuracy: 1e-9,
                       "a value-less setBPM cannot poison the grid")
    }

    func testReplayWithoutBaseIsNil() {
        let nilGrid = GridReplay.authoritativeGridIfAnalyzed(base: nil, corrections: [correction(op: .doubleBPM)])
        XCTAssertNil(nilGrid, "no detected grid, no authoritative grid — the honest not-analyzed state")
    }

    // MARK: - DB: override without mutating analysis, persists, feeds the grid (§23.3, AT-GRID-*)

    func testCorrectionOverridesWithoutMutatingAnalysisAndPersists() async throws {
        let env = try makeEnvironment()
        let repository = env.repository
        let pool = env.pool
        let trackID = env.trackID

        // Two corrections: set the downbeat at 24 000 and double the tempo.
        try await repository.apply(.setDownbeat, trackID: trackID, valueDouble: nil, valueInt: 24_000)
        try await repository.apply(.doubleBPM, trackID: trackID, valueDouble: nil, valueInt: nil)

        let snapshot = try await repository.snapshot(trackID: trackID)

        // The authoritative grid a deck loads — detected (128 BPM, beat 0 at 0)
        // with both corrections replayed.
        XCTAssertEqual(snapshot.grid?.referenceSample ?? -1, 24_000, accuracy: 1e-9)
        XCTAssertEqual(snapshot.grid?.bpm ?? -1, 256, accuracy: 1e-9, "128 ×2")
        XCTAssertEqual(snapshot.bpm, 256, "the readout shows the authoritative BPM")
        XCTAssertEqual(snapshot.detectedBPM, 128, "the detected BPM is preserved separately")

        // The immutable analysis is untouched: `beat_grid` is still the detected row.
        let raw = try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT bpm, firstBeatSample, source FROM beat_grid WHERE trackID = ?",
                             arguments: [trackID])
        }
        XCTAssertEqual(raw?["bpm"] as? Double, 128)
        XCTAssertEqual(raw?["firstBeatSample"] as? Int64, 0)
        XCTAssertEqual(raw?["source"] as? String, "detected")

        // Persists: a fresh repository over the same DB replays the same grid.
        let fresh = GridCorrectionRepository(pool: pool, store: DJLibraryStore(pool: pool))
        let reloaded = try await fresh.snapshot(trackID: trackID)
        XCTAssertEqual(reloaded.grid?.referenceSample ?? -1, 24_000, accuracy: 1e-9)
        XCTAssertEqual(reloaded.grid?.bpm ?? -1, 256, accuracy: 1e-9)
        XCTAssertEqual(reloaded.corrections.count, 2)
    }

    func testUndoPopsTheNewestCorrectionOnly() async throws {
        let env = try makeEnvironment()
        let repository = env.repository
        let trackID = env.trackID

        try await repository.apply(.setDownbeat, trackID: trackID, valueDouble: nil, valueInt: 12_000)
        try await repository.apply(.doubleBPM, trackID: trackID, valueDouble: nil, valueInt: nil)

        var snapshot = try await repository.snapshot(trackID: trackID)
        XCTAssertEqual(snapshot.corrections.count, 2)

        try await repository.undoLast(trackID: trackID)

        snapshot = try await repository.snapshot(trackID: trackID)
        XCTAssertEqual(snapshot.corrections.count, 1, "undo pops the newest entry")
        XCTAssertEqual(snapshot.grid?.referenceSample ?? -1, 12_000, accuracy: 1e-9,
                       "the setDownbeat survives the undo of the doubleBPM")
        XCTAssertEqual(snapshot.grid?.bpm ?? -1, 128, accuracy: 1e-9,
                       "removing the ×2 restores exactly the prior grid")

        // Undoing the last correction returns the grid to the detected value.
        try await repository.undoLast(trackID: trackID)
        snapshot = try await repository.snapshot(trackID: trackID)
        XCTAssertTrue(snapshot.corrections.isEmpty)
        XCTAssertEqual(snapshot.grid?.referenceSample ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.grid?.bpm ?? -1, 128, accuracy: 1e-9)

        // Undoing an empty log is a no-op, not an error.
        try await repository.undoLast(trackID: trackID)
        snapshot = try await repository.snapshot(trackID: trackID)
        XCTAssertTrue(snapshot.corrections.isEmpty)
    }

    func testSnapshotWithoutAnalysisReportsTheHonestState() async throws {
        let env = try makeEnvironment(seedGrid: false)
        let repository = env.repository
        let trackID = env.trackID

        let snapshot = try await repository.snapshot(trackID: trackID)
        XCTAssertNil(snapshot.grid, "no beat_grid row means no grid yet")
        XCTAssertFalse(snapshot.isAnalyzed)
        XCTAssertEqual(snapshot.corrections.count, 0)
        XCTAssertEqual(snapshot.title, "Undertow Static")
    }

    func testSnapshotReadsTheFreeReadoutRows() async throws {
        let env = try makeEnvironment()
        let pool = env.pool
        let trackID = env.trackID

        // Seed a loudness row + two phrases — the FR-PREP-4 readout data.
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO loudness (trackID, integratedLUFS, dynamicRangeDB, version)
                VALUES (?, ?, ?, ?)
                """, arguments: [trackID, -7.2, 8.0, 1])
            try db.execute(sql: """
                INSERT INTO phrase (syncID, trackID, startSample, endSample, lengthBeats, type, version)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, trackID, 0, 10_000, 16, "intro", 1])
            try db.execute(sql: """
                INSERT INTO phrase (syncID, trackID, startSample, endSample, lengthBeats, type, version)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, trackID, 10_000, 90_000, 32, "drop", 1])
        }

        let snapshot = try await env.repository.snapshot(trackID: trackID)
        XCTAssertEqual(snapshot.lufs ?? -1, -7.2, accuracy: 1e-9, "mockup `ipad/06`'s −7.2 LUFS")
        XCTAssertEqual(snapshot.dynamicRangeDB ?? -1, 8, accuracy: 1e-9)
        XCTAssertEqual(snapshot.phraseCount, 2)
        XCTAssertEqual(snapshot.longestPhraseBeats, 32, "mockup's 'longest 32 bars'")
        XCTAssertEqual(snapshot.gridConfidence ?? -1, 0.97, accuracy: 1e-9)
        XCTAssertEqual(snapshot.grid?.bpm ?? -1, 128, accuracy: 1e-9)
    }

    // MARK: - TempoTapper (pure, FR-PREP-5 tempo tap)

    func testTempoTapperEstimatesFromTapIntervals() {
        var tapper = TempoTapper(sampleRate: 48_000)
        XCTAssertNil(tapper.tap(at: 0), "one tap is not a tempo")
        XCTAssertNil(tapper.tap(at: 24_000), "two taps are not yet a tempo")
        let estimate = tapper.tap(at: 48_000)
        XCTAssertEqual(estimate ?? -1, 120, accuracy: 1e-9, "500 ms apart = 120 BPM")
        XCTAssertEqual(tapper.tapCount, 3)
    }

    func testTempoTapperUsesTheMedianInterval() {
        // A mistimed first tap (0 → 25 000) pulls a mean to ~113.9, but the
        // median interval (24 000 ms) keeps the honest 120.
        var tapper = TempoTapper(sampleRate: 48_000)
        _ = tapper.tap(at: 0)
        _ = tapper.tap(at: 25_000)
        let estimate = tapper.tap(at: 48_000)
        XCTAssertEqual(estimate ?? -1, 120, accuracy: 1e-9,
                       "the median interval is robust to one bad tap")
    }

    func testTempoTapperSlidingWindowAndReset() {
        var tapper = TempoTapper(sampleRate: 48_000)
        for sample in stride(from: Int64(0), through: Int64(96_000), by: 24_000) {
            _ = tapper.tap(at: sample)
        }
        XCTAssertLessThanOrEqual(tapper.tapCount, TempoTapper.tapWindow,
                                 "the window never grows past four taps")
        tapper.reset()
        XCTAssertEqual(tapper.tapCount, 0)
        XCTAssertNil(tapper.tap(at: 0), "after a reset the estimate needs three taps again")
    }

    // MARK: - TrackPrepModel (gate + forwarding, App. T.3)

    func testGateLocksTheGridToolsForFreeUsers() async {
        let fake = FakePrepRepository(snapshot: makeSnapshot())
        let model = TrackPrepModel(repository: fake,
                                   store: makeStore(isPro: false),
                                   trackID: 1)
        await model.refresh()
        XCTAssertFalse(model.isPreparationEnabled,
                       "a free user sees the analysis readout only — the tools render locked (§40.4)")

        await model.doubleBPM()
        XCTAssertTrue(fake.applied.isEmpty, "the intent boundary refuses the edit")
        XCTAssertNotNil(model.lastError, "and states the reason honestly")
        XCTAssertEqual(model.snapshot?.grid?.bpm ?? -1, 128, accuracy: 1e-9, "the grid is untouched")
    }

    func testGateOpensTheGridToolsForProUsers() async throws {
        let fake = FakePrepRepository(snapshot: makeSnapshot())
        let model = TrackPrepModel(repository: fake,
                                   store: makeStore(isPro: true),
                                   trackID: 1)
        await model.refresh()
        XCTAssertTrue(model.isPreparationEnabled)
        XCTAssertEqual(model.snapshot?.bpm ?? -1, 128, accuracy: 1e-9)

        await model.doubleBPM()
        XCTAssertEqual(fake.applied.count, 1)
        XCTAssertEqual(fake.applied[0].op, .doubleBPM)
        XCTAssertEqual(fake.applied[0].trackID, 1)
        XCTAssertNil(fake.applied[0].valueInt)
        XCTAssertNil(fake.lastError, "a Pro edit clears the error state")
    }

    func testNudgeAndSetDownbeatForwardTheirValues() async {
        let fake = FakePrepRepository(snapshot: makeSnapshot())
        let model = TrackPrepModel(repository: fake,
                                   store: makeStore(isPro: true),
                                   trackID: 1)
        await model.refresh()

        await model.nudge(bySamples: 1000)
        await model.setDownbeat(atSample: 24_000)

        XCTAssertEqual(fake.applied.map(\.op), [.nudge, .setDownbeat])
        XCTAssertEqual(fake.applied[0].valueInt, 1000)
        XCTAssertEqual(fake.applied[1].valueInt, 24_000)
        XCTAssertEqual(fake.applied[0].valueDouble, nil)
    }

    func testUndoForwardsThroughTheRepository() async {
        let fake = FakePrepRepository(snapshot: makeSnapshot())
        let model = TrackPrepModel(repository: fake,
                                   store: makeStore(isPro: true),
                                   trackID: 1)
        await model.refresh()

        await model.undoLast()
        XCTAssertEqual(fake.undoCount, 1)
        XCTAssertEqual(fake.snapshotCount, 2, "refresh re-reads the snapshot after the undo")
    }

    func testTempoTapAppliesTheEstimatedBPM() async {
        let fake = FakePrepRepository(snapshot: makeSnapshot())
        let model = TrackPrepModel(repository: fake,
                                   store: makeStore(isPro: true),
                                   trackID: 1)
        await model.refresh()

        let firstTap: Double? = await model.tempoTap(atSample: 0)
        let secondTap: Double? = await model.tempoTap(atSample: 24_000)
        let estimate: Double? = await model.tempoTap(atSample: 48_000)
        XCTAssertNil(firstTap)
        XCTAssertNil(secondTap)
        XCTAssertEqual(estimate ?? -1, 120, accuracy: 1e-9)
        XCTAssertEqual(fake.applied.count, 1, "one setBPM correction from the three taps")
        XCTAssertEqual(fake.applied[0].op, .setBPM)
        XCTAssertEqual(fake.applied[0].valueDouble ?? -1, 120, accuracy: 1e-9)
    }

    func testRefreshSurfacesTheRepositoryError() async {
        let fake = FakePrepRepository(snapshot: makeSnapshot(), failWith: PrepError.trackNotFound)
        let model = TrackPrepModel(repository: fake,
                                   store: makeStore(isPro: true),
                                   trackID: 404)
        await model.refresh()
        XCTAssertNil(model.snapshot)
        XCTAssertNotNil(model.lastError, "a missing track is reported, not silently ignored")
    }

    // MARK: - Fixtures

    private struct Environment {
        let repository: GridCorrectionRepository
        let pool: DatabasePool
        let trackID: Int64
    }

    private func makeEnvironment(seedGrid: Bool = true) throws -> Environment {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GridCorrectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        let store = DJLibraryStore(pool: pool)

        var track = DJTrack(syncID: UUID().uuidString,
                            title: "Undertow Static",
                            codec: "FLAC",
                            contentHash: "seed-hash-1",
                            sortKey: "undertow-static",
                            bpm: 128,
                            addedAt: fixedDate,
                            updatedAt: fixedDate)
        try pool.write { db in try track.insert(db) }
        guard let trackID = track.id else { throw PrepError.trackNotFound }

        if seedGrid {
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO beat_grid
                        (trackID, syncID, bpm, firstBeatSample, beatCount,
                         isConstantTempo, source, confidence, version, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [trackID, UUID().uuidString, 128.0, 0, 1024,
                                     true, "detected", 0.97, 1, fixedDate])
            }
        }
        return Environment(repository: GridCorrectionRepository(pool: pool, store: store),
                           pool: pool,
                           trackID: trackID)
    }

    private func makeSnapshot() -> TrackPrepSnapshot {
        TrackPrepSnapshot(
            trackID: 1,
            title: "Undertow Static",
            artistNames: "Kell Vasse",
            codec: "FLAC",
            durationSec: 300,
            bpm: 128,
            detectedBPM: 128,
            camelot: "9A",
            musicalKey: "A minor",
            energy: 7.8,
            lufs: -7.2,
            dynamicRangeDB: 8,
            gridConfidence: 0.97,
            firstBeatSample: 0,
            phraseCount: 6,
            longestPhraseBeats: 32,
            corrections: [],
            grid: DeckGrid(referenceSample: 0, bpm: 128, beatsPerBar: 4, sampleRate: 48_000))
    }

    private func correction(op: GridCorrectionOp,
                            valueDouble: Double? = nil,
                            valueInt: Int64? = nil,
                            appliedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> GridCorrection {
        GridCorrection(syncID: UUID().uuidString,
                       trackID: 1,
                       op: op.rawValue,
                       valueDouble: valueDouble,
                       valueInt: valueInt,
                       appliedAt: appliedAt)
    }

    private struct EmptyEntitlementSource: EntitlementSource {
        func currentTransactions() async throws -> [TransactionFact] { [] }
        func transactionUpdates() -> AsyncStream<TransactionFact> { AsyncStream { _ in } }
    }

    private func makeStore(isPro: Bool) -> EntitlementStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GridCorrectionTests-\(UUID().uuidString)", isDirectory: true)
        let cacheURL = dir.appendingPathComponent("entitlement-cache.json")
        EntitlementCacheStore(fileURL: cacheURL).save(
            EntitlementCache(isPro: isPro, source: isPro ? .purchased : .none, timestamp: Date()))
        return EntitlementStore(entitlementSource: EmptyEntitlementSource(),
                                cacheStore: EntitlementCacheStore(fileURL: cacheURL))
    }

    /// The recording fake repository the model tests inject (the §47.2 VM tier).
    @MainActor
    private final class FakePrepRepository: TrackPrepRepositing {
        var snapshotToReturn: TrackPrepSnapshot
        let failWith: PrepError?
        private(set) var applied: [(op: GridCorrectionOp, trackID: Int64,
                                    valueDouble: Double?, valueInt: Int64?)] = []
        private(set) var undoCount = 0
        private(set) var snapshotCount = 0
        private(set) var lastError: String?

        init(snapshot: TrackPrepSnapshot, failWith: PrepError? = nil) {
            self.snapshotToReturn = snapshot
            self.failWith = failWith
        }

        func snapshot(trackID: Int64) async throws -> TrackPrepSnapshot {
            snapshotCount += 1
            if let failWith { throw failWith }
            return snapshotToReturn
        }

        func apply(_ op: GridCorrectionOp, trackID: Int64,
                   valueDouble: Double?, valueInt: Int64?) async throws {
            applied.append((op, trackID, valueDouble, valueInt))
        }

        func undoLast(trackID: Int64) async throws {
            undoCount += 1
        }
    }
}
