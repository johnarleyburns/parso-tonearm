import XCTest
import GRDB

@testable import TonearmDJ

/// AutoPlaylistModel (plan §3.4, §41.6–41.7): the fake-generator seam mirroring
/// `VibeSearching`; the generating / result / honest-short-pool / error states;
/// chip-parse edits feeding the request; lock / reject / replace / extend /
/// reshuffle; save-as-playlist and save-as-smart-crate (brief → `VibeQuery` →
/// `SmartCrateRepository`); and FR-PLIST-10's session-scoped card dismissal.
@MainActor
final class AutoPlaylistModelTests: XCTestCase {

    // MARK: - Fakes

    /// Records every request and interaction, answering from a scripted queue of
    /// `PlaylistGeneration`s (or a default when empty).
    private final class RecordingGenerator: AutoPlaylistGenerating, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [PlaylistGenerationRequest] = []
        private var _queue: [Result<PlaylistGeneration, PlaylistGeneratorError>] = []
        private var _saveTitles: [String] = []
        private var _playlistID: Int64 = 77
        private var _rejected: [Int64] = []
        private var _replaceSlots: [Int] = []
        private var _extendedMinutes: [Int] = []
        private var _reshuffles: [(Int, Int)] = []

        private func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }
            return try body()
        }

        var requests: [PlaylistGenerationRequest] { withLock { _requests } }
        var saveTitles: [String] { withLock { _saveTitles } }
        var rejected: [Int64] { withLock { _rejected } }
        var replaceSlots: [Int] { withLock { _replaceSlots } }
        var extendedMinutes: [Int] { withLock { _extendedMinutes } }
        var reshuffles: [(Int, Int)] { withLock { _reshuffles } }
        var savedPlaylistID: Int64? { withLock { _playlistID } }

        func enqueue(_ generation: PlaylistGeneration) {
            withLock { _queue.append(.success(generation)) }
        }

        func enqueueError(_ error: PlaylistGeneratorError) {
            withLock { _queue.append(.failure(error)) }
        }

        func generate(_ request: PlaylistGenerationRequest) async throws -> PlaylistGeneration {
            withLock { _requests.append(request) }
            return try next()
        }

        func reject(trackID: Int64) async throws -> PlaylistGeneration {
            withLock { _rejected.append(trackID) }
            return try next()
        }

        func replaceSlot(slot: Int) async throws -> PlaylistGeneration {
            withLock { _replaceSlots.append(slot) }
            return try next()
        }

        func extend(minutes: Int) async throws -> PlaylistGeneration {
            withLock { _extendedMinutes.append(minutes) }
            return try next()
        }

        func reshuffle(from: Int, to: Int) async throws -> PlaylistGeneration {
            withLock { _reshuffles.append((from, to)) }
            return try next()
        }

        func saveAsPlaylist(title: String) async throws -> Int64 {
            withLock { _saveTitles.append(title) }
            return withLock { _playlistID }
        }

        private func next() throws -> PlaylistGeneration {
            try withLock { () -> PlaylistGeneration in
                if _queue.isEmpty { return Self.sampleGeneration() }
                let result = _queue.removeFirst()
                return try result.get()
            }
        }

        /// A deterministic scripted generation: `count` items at trackIDs
        /// 1...count (or the supplied ids), a 2-hour result, arc error 0.07 and
        /// mean transition cost 0.18.
        static func sampleGeneration(isShortPool: Bool = false, count: Int = 4,
                                     trackIDs: [Int64]? = nil) -> PlaylistGeneration {
            let ids = trackIDs ?? (1...count).map { Int64($0) }
            let constraints = (try? SequencingConstraints().encodedJSONString()) ?? "{}"
            let brief = AutoPlaylistBrief(syncID: "B-\(UUID().uuidString)",
                                          prompt: "test",
                                          arcKind: "build",
                                          constraintsJSON: constraints,
                                          randomSeed: 1,
                                          createdAt: Date(),
                                          updatedAt: Date())
            let result = AutoPlaylistResult(briefID: 1,
                                            generatedAt: Date(),
                                            totalSeconds: 7200,
                                            arcError: 0.07,
                                            meanTransitionCost: 0.18,
                                            analysisVersion: AnalysisVersions.embedding)
            let items = ids.enumerated().map { index, trackID in
                AutoPlaylistItem(resultID: 1,
                                 trackID: trackID,
                                 position: index,
                                 locked: false,
                                 targetEnergy: 0.5,
                                 actualEnergy: ids.count > 1
                                     ? Double(index) / Double(ids.count - 1) : 0.5,
                                 transitionCostIn: index == 0 ? 0 : 0.1,
                                 semanticScore: 0.5)
            }
            return PlaylistGeneration(brief: brief,
                                      result: result,
                                      items: items,
                                      requestedCount: count,
                                      candidateCount: count + 10,
                                      isShortPool: isShortPool)
        }
    }

    /// Blocks the first `generate` on a continuation so a test can observe the
    /// honest in-flight state (mirrors `GatedSearch` in `SearchModelTests`).
    private final class GatedGenerator: AutoPlaylistGenerating, @unchecked Sendable {
        private let lock = NSLock()
        private var _blockNext = true
        private var _pending: [CheckedContinuation<Void, Never>] = []

        private func withLock<T>(_ body: () throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }
            return try body()
        }

        func generate(_ request: PlaylistGenerationRequest) async throws -> PlaylistGeneration {
            let shouldBlock = withLock { () -> Bool in
                let block = _blockNext
                _blockNext = false
                return block
            }
            if shouldBlock {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    withLock { _pending.append(continuation) }
                }
            }
            return RecordingGenerator.sampleGeneration(count: 3)
        }

        func release() {
            let pending = withLock { () -> [CheckedContinuation<Void, Never>] in
                let current = _pending
                _pending = []
                return current
            }
            for continuation in pending { continuation.resume() }
        }

        func reject(trackID: Int64) async throws -> PlaylistGeneration {
            RecordingGenerator.sampleGeneration(count: 3)
        }

        func replaceSlot(slot: Int) async throws -> PlaylistGeneration {
            RecordingGenerator.sampleGeneration(count: 3)
        }

        func extend(minutes: Int) async throws -> PlaylistGeneration {
            RecordingGenerator.sampleGeneration(count: 3)
        }

        func reshuffle(from: Int, to: Int) async throws -> PlaylistGeneration {
            RecordingGenerator.sampleGeneration(count: 3)
        }

        func saveAsPlaylist(title: String) async throws -> Int64 { 1 }
    }

    // MARK: - Environment

    private func makePool() throws -> DatabasePool {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoPlaylistModelTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
    }

    private func makeModel(generator: any AutoPlaylistGenerating,
                           pool: DatabasePool? = nil) throws -> AutoPlaylistModel {
        let databasePool = try pool ?? makePool()
        return AutoPlaylistModel(generator: generator,
                                 crateRepository: SmartCrateRepository(pool: databasePool),
                                 trackRepository: DJTrackRepository(pool: databasePool))
    }

    /// Poll until a main-actor condition holds, so the async test can observe
    /// in-flight model state deterministically. Uses `Task.sleep`, the proven
    /// `SearchModelTests` pattern — `Task.yield` can starve a just-spawned task.
    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: @MainActor @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Prompt → chips (§28A.6)

    func testPromptParseFeedsEditableChipsAndDropRemovesTerm() async throws {
        let model = try makeModel(generator: RecordingGenerator())
        model.prompt = "two hours for a dinner party — starts warm and conversational, "
            + "builds after the food, ends euphoric but not stupid. nothing with shouty vocals."

        XCTAssertTrue(model.chips.contains { $0.kind == .duration },
                      "the extractor read the duration")
        XCTAssertTrue(model.chips.contains { $0.kind == .arc },
                      "the extractor read an arc phrase")
        XCTAssertTrue(model.chips.contains { $0.kind == .negative && $0.label == "shouty vocals" })
        XCTAssertEqual(model.targetSeconds, 2 * 3600)
        if case .peakAndRelease = model.arc {
        } else {
            XCTFail("ends euphoric should parse to peakAndRelease, got \(model.arc)")
        }

        let shouty = try XCTUnwrap(model.chips.first { $0.kind == .negative })
        model.removeChip(shouty)
        XCTAssertFalse(model.chips.contains { $0.label == "shouty vocals" })
        XCTAssertTrue(model.currentRequest.negativeTerms.isEmpty,
                      "a dropped term chip must not reach the generator")
    }

    func testRequestCarriesChipsArcLengthAndConstraints() async throws {
        let model = try makeModel(generator: RecordingGenerator())
        model.prompt = "steady around 120 bpm, no vocals"
        model.arc = .wave(cycles: 2)

        let request = model.currentRequest
        XCTAssertEqual(request.arc, .wave(cycles: 2))
        XCTAssertEqual(request.constraints.bpmRange, 120...120)
        XCTAssertEqual(request.negativeTerms, ["vocals"])
        XCTAssertNotNil(request.targetSeconds, "duration mode is the default")
        XCTAssertNil(request.targetTrackCount)

        model.useTrackCount = true
        model.targetTrackCount = 25
        let countRequest = model.currentRequest
        XCTAssertNil(countRequest.targetSeconds)
        XCTAssertEqual(countRequest.targetTrackCount, 25)
    }

    // MARK: - Generation states

    func testGenerateProducesRowsAndState() async throws {
        let generator = RecordingGenerator()
        let model = try makeModel(generator: generator)
        generator.enqueue(RecordingGenerator.sampleGeneration(count: 4,
                                                              trackIDs: [10, 11, 12, 13]))

        await model.generate()

        XCTAssertFalse(model.isGenerating)
        XCTAssertNotNil(model.generation)
        XCTAssertEqual(model.rows.count, 4)
        XCTAssertEqual(model.rows[0].trackID, 10)
        XCTAssertEqual(model.rows[0].position, 0)
        XCTAssertEqual(model.rows.map(\.position), [0, 1, 2, 3])
        XCTAssertNotNil(model.lastGenerationMillis)
        XCTAssertEqual(model.arcError, 0.07)
        XCTAssertEqual(model.meanTransitionCost, 0.18)
        XCTAssertEqual(model.totalSeconds, 7200)
        XCTAssertEqual(generator.requests.count, 1)
    }

    func testGeneratingStateDuringInFlightGeneration() async throws {
        let gate = GatedGenerator()
        let model = try makeModel(generator: gate)

        let task = Task { await model.generate() }
        await waitUntil { model.isGenerating }

        XCTAssertTrue(model.isGenerating, "the state must be honest while the generator runs")
        gate.release()
        await task.value

        XCTAssertFalse(model.isGenerating)
        XCTAssertNotNil(model.generation)
    }

    func testErrorSurfacedNotResult() async throws {
        let generator = RecordingGenerator()
        let model = try makeModel(generator: generator)
        generator.enqueueError(.noCandidates)

        await model.generate()

        XCTAssertNil(model.generation)
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.lastError,
                       PlaylistGeneratorError.noCandidates.errorDescription)
    }

    func testShortPoolStateSurfaced() async throws {
        let generator = RecordingGenerator()
        let model = try makeModel(generator: generator)
        generator.enqueue(RecordingGenerator.sampleGeneration(isShortPool: true, count: 5))

        await model.generate()

        XCTAssertTrue(model.isShortPool, "the honest short-pool state must be surfaced")
        XCTAssertEqual(model.requestedCount, 5)
        XCTAssertEqual(model.rows.count, 5)
    }

    // MARK: - Interactions (§28A.4)

    func testLockTogglePinsSlotAndIsPassedOnRegenerate() async throws {
        let generator = RecordingGenerator()
        let model = try makeModel(generator: generator)
        generator.enqueue(RecordingGenerator.sampleGeneration(count: 4))
        await model.generate()

        model.toggleLock(at: 1)
        XCTAssertTrue(model.isLocked(at: 1))
        XCTAssertEqual(model.currentRequest.locks[1], model.rows[1].trackID,
                       "locking pins the slot's track")

        generator.enqueue(RecordingGenerator.sampleGeneration(count: 4))
        await model.generate()
        let regenerated = generator.requests.last
        XCTAssertEqual(regenerated?.locks[1], model.rows[1].trackID,
                       "the lock rides on the constrained re-run")

        model.toggleLock(at: 1)
        XCTAssertFalse(model.isLocked(at: 1))
        XCTAssertNil(model.currentRequest.locks[1])
    }

    func testRejectRegeneratesAndCounts() async throws {
        let generator = RecordingGenerator()
        let model = try makeModel(generator: generator)
        generator.enqueue(RecordingGenerator.sampleGeneration(count: 3))
        await model.generate()
        let rejectedTrack = model.rows[1].trackID

        generator.enqueue(RecordingGenerator.sampleGeneration(count: 3))
        await model.reject(trackID: rejectedTrack)

        XCTAssertEqual(model.rejectionCount, 1)
        XCTAssertEqual(generator.rejected, [rejectedTrack])
        XCTAssertNotNil(model.generation)
    }

    func testReplaceExtendReshufflePassThrough() async throws {
        let generator = RecordingGenerator()
        let model = try makeModel(generator: generator)
        generator.enqueue(RecordingGenerator.sampleGeneration(count: 4))
        await model.generate()

        generator.enqueue(RecordingGenerator.sampleGeneration(count: 4))
        await model.replaceSlot(slot: 2)
        XCTAssertEqual(generator.replaceSlots, [2])

        generator.enqueue(RecordingGenerator.sampleGeneration(count: 5))
        await model.extend(minutes: 30)
        XCTAssertEqual(generator.extendedMinutes, [30])

        generator.enqueue(RecordingGenerator.sampleGeneration(count: 4))
        await model.reshuffle(from: 1, to: 3)
        XCTAssertEqual(generator.reshuffles.count, 1)
        XCTAssertEqual(generator.reshuffles[0].0, 1)
        XCTAssertEqual(generator.reshuffles[0].1, 3)
    }

    // MARK: - Save (FR-PLIST-7, §41.7)

    func testSaveAsPlaylistPassesTitle() async throws {
        let generator = RecordingGenerator()
        let model = try makeModel(generator: generator)
        generator.enqueue(RecordingGenerator.sampleGeneration(count: 3))
        await model.generate()

        await model.saveAsPlaylist(title: "Dinner Set")

        XCTAssertEqual(generator.saveTitles, ["Dinner Set"])
        XCTAssertEqual(model.savedPlaylistID, generator.savedPlaylistID)
    }

    func testSaveAsSmartCratePersistsBriefAsQuery() async throws {
        let pool = try makePool()
        let model = try makeModel(generator: RecordingGenerator(), pool: pool)
        model.prompt = "warm and conversational, no shouty vocals"

        model.saveAsSmartCrate(name: "Dinner set")

        let crateID = try XCTUnwrap(model.savedCrateID)
        let crateRow = try await pool.read { db in
            try SmartCrate.fetchOne(db, key: crateID)
        }
        let crate = try XCTUnwrap(crateRow)
        XCTAssertEqual(crate.name, "Dinner set")
        let query = try VibeQuery.decodeJSON(crate.queryJSON)
        XCTAssertEqual(query.text, "warm and conversational, no shouty vocals")
        XCTAssertEqual(query.negativeTerms, ["shouty vocals"],
                       "the brief's − chips become the crate's negative terms")
    }

    // MARK: - Rows carry track metadata

    func testRowsCarryTrackMetadata() async throws {
        let pool = try makePool()
        let ids = try await seedTracks(pool: pool, count: 2)
        let generator = RecordingGenerator()
        let model = try makeModel(generator: generator, pool: pool)
        generator.enqueue(RecordingGenerator.sampleGeneration(count: 2, trackIDs: ids))

        await model.generate()

        XCTAssertEqual(model.rows[0].title, "Track 0")
        XCTAssertEqual(model.rows[0].artistNames, "Artist 0")
        XCTAssertEqual(model.rows[0].bpm, 120)
        XCTAssertEqual(model.rows[0].camelot, "8A")
        XCTAssertEqual(model.rows[1].title, "Track 1")
        XCTAssertEqual(model.rows[1].artistNames, "Artist 1")
    }

    private func seedTracks(pool: DatabasePool, count: Int) async throws -> [Int64] {
        var ids: [Int64] = []
        for index in 0..<count {
            let artistSeed = DJArtist(syncID: "A-\(UUID().uuidString)",
                                      name: "Artist \(index)",
                                      sortName: "artist \(index)",
                                      createdAt: Date())
            let trackSeed = DJTrack(syncID: "T-\(UUID().uuidString)",
                                    title: "Track \(index)",
                                    durationSec: 200,
                                    contentHash: "hash-\(index)",
                                    sortKey: "t-\(index)",
                                    bpm: 120 + Double(index),
                                    camelot: "8A",
                                    energy: 5,
                                    analysisState: "done",
                                    addedAt: Date(),
                                    updatedAt: Date())
            let id = try await pool.write { db -> Int64 in
                var artist = artistSeed
                var track = trackSeed
                try artist.insert(db)
                try track.insert(db)
                let trackID = try XCTUnwrap(track.id)
                let artistID = try XCTUnwrap(artist.id)
                try db.execute(sql: """
                    INSERT INTO track_artist (trackID, artistID, position) VALUES (?, ?, 0)
                    """, arguments: [trackID, artistID])
                return trackID
            }
            ids.append(id)
        }
        return ids
    }

    // MARK: - Seed track

    func testSeedSetsAndClears() async throws {
        let model = try makeModel(generator: RecordingGenerator())
        model.setSeed(trackID: 42, label: "Glasshouse Interval · Ede Marlow")
        XCTAssertEqual(model.currentRequest.seedTrackID, 42)
        XCTAssertEqual(model.seedTrackLabel, "Glasshouse Interval · Ede Marlow")

        model.clearSeed()
        XCTAssertNil(model.currentRequest.seedTrackID)
        XCTAssertNil(model.seedTrackLabel)
    }

    // MARK: - FR-PLIST-10 (session-scoped dismissal)

    func testBlendCardIsSessionRemembered() async throws {
        let generator = RecordingGenerator()
        let model = try makeModel(generator: generator)
        XCTAssertFalse(model.showsBlendCard, "no card before a result exists")

        generator.enqueue(RecordingGenerator.sampleGeneration(count: 3))
        await model.generate()
        XCTAssertTrue(model.showsBlendCard)

        model.dismissBlendCard()
        XCTAssertFalse(model.showsBlendCard,
                       "dismissed once, the card must not reappear this session")

        generator.enqueue(RecordingGenerator.sampleGeneration(count: 3))
        await model.generate()
        XCTAssertFalse(model.showsBlendCard,
                       "still dismissed after a regenerate in the same session")

        let fresh = try makeModel(generator: RecordingGenerator())
        generator.enqueue(RecordingGenerator.sampleGeneration(count: 2))
        await fresh.generate()
        XCTAssertTrue(fresh.showsBlendCard,
                      "a fresh model is a fresh session — the card may show again")
    }

    // MARK: - Helpers

    func testTitleAndDurationHelpers() {
        XCTAssertEqual(AutoPlaylistModel.title(for: "two hours for a dinner party"),
                       "Two hours for a dinner")
        XCTAssertEqual(AutoPlaylistModel.title(for: "   "), "Generated playlist")
        XCTAssertEqual(AutoPlaylistModel.durationText(2 * 3600), "2:00:00")
        XCTAssertEqual(AutoPlaylistModel.durationText(45 * 60), "45:00")
        XCTAssertEqual(AutoPlaylistModel.durationText(90 * 60), "1:30:00")
    }
}
