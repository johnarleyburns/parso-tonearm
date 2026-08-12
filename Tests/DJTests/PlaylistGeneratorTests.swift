import XCTest
import GRDB

@testable import TonearmDJ

/// PlaylistGenerator + AutoPlaylistRepository (plan §3.3): fake-embedder
/// end-to-end, brief→sequence→persist atomicity, rejection exclusion, locks
/// honoured on regenerate, the honest short-pool state, and the byte-exact
/// `constraintsJSON` / sync-mapping round-trips.
final class PlaylistGeneratorTests: XCTestCase {

    private let storeDims = 32

    // MARK: - Environment

    private func makeSpec() -> EmbeddingModelSpec {
        let fftSize = 256
        let bins = fftSize / 2 + 1
        return EmbeddingModelSpec(modelName: "plist-test",
                                  dimensions: storeDims,
                                  sampleRate: 48_000,
                                  windowSeconds: 0.5,
                                  hopSeconds: 0.25,
                                  fftSize: fftSize,
                                  hopSize: 120,
                                  melBins: 8,
                                  lowHz: 50,
                                  highHz: 14_000,
                                  clipSamples: 24_000,
                                  frames: 201,
                                  maxWindows: 240,
                                  textMaxLength: 77,
                                  pooling: .attention,
                                  melFilterBank: [Float](repeating: 1, count: bins * 8))
    }

    private func makeEmbedder() -> CLAPEmbedder {
        CLAPEmbedder(model: DeterministicFakeSemanticModel(spec: makeSpec()))
    }

    private func makeEnvironment(trackCount: Int) async throws
        -> (pool: DatabasePool, generator: PlaylistGenerator, trackIDs: [Int64]) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistGeneratorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        let store = try VectorStoreTierA(pool: pool, dims: storeDims,
                                         fileURL: dir.appendingPathComponent("vectors.i8"))
        let embedder = makeEmbedder()
        let generator = PlaylistGenerator(pool: pool, store: store, embedder: embedder)

        var trackIDs: [Int64] = []
        for index in 0..<trackCount {
            let id = try await seedTrack(index: index, in: pool, store: store, embedder: embedder)
            trackIDs.append(id)
        }
        return (pool, generator, trackIDs)
    }

    private func seedTrack(index: Int, in pool: DatabasePool, store: any VectorStore,
                           embedder: CLAPEmbedder) async throws -> Int64 {
        let track = DJTrack(syncID: UUID().uuidString,
                            title: "Track \(index)",
                            durationSec: 180 + Double((index % 12) * 20),
                            contentHash: "hash-\(UUID().uuidString)",
                            sortKey: "track-\(String(format: "%04d", index))",
                            bpm: 110 + Double(index % 40),
                            camelot: "\((index % 12) + 1)\(index % 2 == 0 ? "A" : "B")",
                            energy: Double(index % 10),
                            analysisState: "done",
                            addedAt: Date(),
                            updatedAt: Date())
        let inserted = try await pool.write { db -> DJTrack in
            var stored = track
            try stored.insert(db)
            return stored
        }
        let trackID = try XCTUnwrap(inserted.id)
        let vector = try await embedder.embedText("seed phrase \(index)")
        let (int8, scale) = Quantization.quantize(vector)
        try await pool.write { db in
            try store.upsert(DJTrackEmbedding(trackID: trackID, int8Vector: int8,
                                              scale: Double(scale), matrixRow: nil,
                                              version: 1),
                             db: db)
        }
        return trackID
    }

    private func request(prompt: String = "rainy sunday dinner",
                         arc: EnergyArc = .build,
                         targetSeconds: Double = 3600,
                         targetTrackCount: Int? = nil,
                         constraints: SequencingConstraints = SequencingConstraints(),
                         seedTrackID: Int64? = nil,
                         randomSeed: UInt64 = 42,
                         locks: [Int: Int64] = [:]) -> PlaylistGenerationRequest {
        PlaylistGenerationRequest(prompt: prompt,
                                  arc: arc,
                                  targetSeconds: targetSeconds,
                                  targetTrackCount: targetTrackCount,
                                  constraints: constraints,
                                  seedTrackID: seedTrackID,
                                  randomSeed: randomSeed,
                                  locks: locks)
    }

    // MARK: - End-to-end

    func testGeneratePersistsBriefResultAndItems() async throws {
        let env = try await makeEnvironment(trackCount: 30)
        defer { try? env.pool.close() }

        let generation = try await env.generator.generate(request())

        // Brief persisted with the request's fields.
        let briefID = try XCTUnwrap(generation.brief.id)
        XCTAssertEqual(generation.brief.arcKind, "build")
        XCTAssertEqual(generation.brief.prompt, "rainy sunday dinner")
        XCTAssertNotNil(try AutoPlaylistRepository(pool: env.pool).brief(id: briefID))

        // Result persisted, items in order, no duplicates, positions dense.
        XCTAssertNotNil(generation.result.id)
        XCTAssertEqual(generation.items.map(\.position), Array(0..<generation.items.count))
        let ids = generation.items.map(\.trackID)
        XCTAssertEqual(Set(ids).count, ids.count)

        // The repository reloads the brief's latest result with its items.
        let latest = try XCTUnwrap(try AutoPlaylistRepository(pool: env.pool)
            .latestResult(for: briefID))
        XCTAssertEqual(latest.items.map(\.trackID), ids)
        XCTAssertEqual(latest.result.totalSeconds, generation.result.totalSeconds)
        XCTAssertEqual(latest.result.analysisVersion, AnalysisVersions.embedding)
    }

    func testGenerationIsDeterministicForSameSeed() async throws {
        let env = try await makeEnvironment(trackCount: 40)
        defer { try? env.pool.close() }

        let first = try await env.generator.generate(request(randomSeed: 0x1234))
        let second = try await env.generator.generate(request(randomSeed: 0x1234))
        XCTAssertEqual(first.items.map(\.trackID), second.items.map(\.trackID),
                       "same brief + seed + library ⇒ byte-identical sequence (NFR-DET-1)")
    }

    // MARK: - Persist atomicity (NFR-REL-1)

    func testPersistRollsBackAtomicallyOnFailedItemInsert() async throws {
        let env = try await makeEnvironment(trackCount: 4)
        defer { try? env.pool.close() }
        let repository = AutoPlaylistRepository(pool: env.pool)
        let brief = AutoPlaylistBrief(syncID: "B-\(UUID().uuidString)", prompt: "x",
                                      arcKind: "build",
                                      constraintsJSON: try SequencingConstraints().encodedJSONString(),
                                      randomSeed: 1, createdAt: Date(), updatedAt: Date())
        let result = AutoPlaylistResult(briefID: 0, generatedAt: Date(), totalSeconds: 1,
                                        arcError: 0, meanTransitionCost: 0, analysisVersion: 1)
        let good = AutoPlaylistItem(resultID: 0, trackID: env.trackIDs[0], position: 0,
                                    targetEnergy: 0.5, actualEnergy: 0.5,
                                    transitionCostIn: 0, semanticScore: 0.5)
        let orphan = AutoPlaylistItem(resultID: 0, trackID: 999_999, position: 1,
                                      targetEnergy: 0.5, actualEnergy: 0.5,
                                      transitionCostIn: 0, semanticScore: 0.5)
        XCTAssertThrowsError(try repository.save(brief: brief, result: result,
                                                 items: [good, orphan]))
        let briefCount = try await env.pool.read { try AutoPlaylistBrief.fetchCount($0) }
        let resultCount = try await env.pool.read { try AutoPlaylistResult.fetchCount($0) }
        XCTAssertEqual(briefCount, 0, "failed save left no brief")
        XCTAssertEqual(resultCount, 0, "failed save left no result")
    }

    // MARK: - Rejection exclusion (§28A.4)

    func testRejectedTrackIsExcludedOnRegenerate() async throws {
        let env = try await makeEnvironment(trackCount: 30)
        defer { try? env.pool.close() }

        let first = try await env.generator.generate(request())
        let rejected = first.items[3].trackID
        let briefID = try XCTUnwrap(first.brief.id)

        let second = try await env.generator.reject(trackID: rejected)

        XCTAssertFalse(second.items.map(\.trackID).contains(rejected),
                       "rejected track re-appeared after reject + re-run")
        XCTAssertTrue(try AutoPlaylistRepository(pool: env.pool)
            .rejections(for: briefID).contains(rejected))
    }

    // MARK: - Locks honoured on regenerate (FR-PLIST-6)

    func testLocksAreHonouredOnGenerateAndRegenerate() async throws {
        let env = try await makeEnvironment(trackCount: 30)
        defer { try? env.pool.close() }

        let lockedTrack = env.trackIDs[4]
        let locked = request(locks: [0: lockedTrack])
        let first = try await env.generator.generate(locked)
        XCTAssertEqual(first.items[0].trackID, lockedTrack)
        XCTAssertTrue(first.items[0].locked)

        let second = try await env.generator.generate(locked)
        XCTAssertEqual(second.items[0].trackID, lockedTrack)
        XCTAssertEqual(second.items.filter { $0.trackID == lockedTrack }.count, 1)
    }

    // MARK: - Audio-seeded briefs (AT-PLIST-2 fast path)

    func testSeedTrackPinsSlotZeroAndAnchorsSemantically() async throws {
        let env = try await makeEnvironment(trackCount: 30)
        defer { try? env.pool.close() }

        let seedID = env.trackIDs[7]
        let generation = try await env.generator.generate(
            request(prompt: "", seedTrackID: seedID))

        XCTAssertEqual(generation.items[0].trackID, seedID, "seed track opens the playlist")
        XCTAssertEqual(generation.items.filter { $0.trackID == seedID }.count, 1,
                       "seed track appears nowhere else")
    }

    // MARK: - Honest short pool (plan §2.7)

    func testShortPoolGeneratesWhatIsPossibleAndSaysSo() async throws {
        let env = try await makeEnvironment(trackCount: 5)
        defer { try? env.pool.close() }

        let generation = try await env.generator.generate(
            request(targetTrackCount: 20))
        XCTAssertEqual(generation.requestedCount, 20)
        XCTAssertEqual(generation.candidateCount, 5)
        XCTAssertTrue(generation.isShortPool, "pool is short — must say so, never pad")
        XCTAssertEqual(generation.items.count, 5, "generates what is possible")
    }

    func testNoAnchorWhenNothingToSearchFor() async throws {
        let env = try await makeEnvironment(trackCount: 5)
        defer { try? env.pool.close() }
        do {
            _ = try await env.generator.generate(
                PlaylistGenerationRequest(prompt: "   ", arc: .build, randomSeed: 1))
            XCTFail("expected .noAnchor")
        } catch let error as PlaylistGeneratorError {
            XCTAssertEqual(error, .noAnchor)
        }
    }

    // MARK: - Replace / extend / reshuffle (§28A.4)

    func testReplaceSlotHoldsNeighbours() async throws {
        let env = try await makeEnvironment(trackCount: 40)
        defer { try? env.pool.close() }

        let first = try await env.generator.generate(request())
        XCTAssertGreaterThan(first.items.count, 5)
        let before = first.items
        let slot = 3

        let second = try await env.generator.replaceSlot(slot: slot)

        XCTAssertNotEqual(second.items[slot].trackID, before[slot].trackID,
                          "replace swapped the slot's track")
        XCTAssertEqual(second.items[slot - 1].trackID, before[slot - 1].trackID,
                       "previous neighbour held")
        XCTAssertEqual(second.items[slot + 1].trackID, before[slot + 1].trackID,
                       "next neighbour held")
    }

    func testExtendReParameterisesArcOverNewLength() async throws {
        let env = try await makeEnvironment(trackCount: 40)
        defer { try? env.pool.close() }

        let first = try await env.generator.generate(request(targetSeconds: 1800))
        let second = try await env.generator.extend(minutes: 30)
        XCTAssertEqual(second.brief.targetSeconds, 1800 + 30 * 60)
        XCTAssertGreaterThanOrEqual(second.items.count, first.items.count,
                                    "extending grows the sequence")
    }

    func testReshuffleKeepsEndpointsFixed() async throws {
        let env = try await makeEnvironment(trackCount: 40)
        defer { try? env.pool.close() }

        let first = try await env.generator.generate(request())
        XCTAssertGreaterThan(first.items.count, 7)
        let second = try await env.generator.reshuffle(from: 2, to: 5)
        XCTAssertEqual(second.items[0].trackID, first.items[0].trackID, "head pinned")
        XCTAssertEqual(second.items[1].trackID, first.items[1].trackID, "pre-range pinned")
        XCTAssertEqual(second.items[6].trackID, first.items[6].trackID, "post-range pinned")
    }

    // MARK: - Static save (FR-PLIST-7)

    func testSaveAsPlaylistPersistsStaticRowsAndLinksResult() async throws {
        let env = try await makeEnvironment(trackCount: 30)
        defer { try? env.pool.close() }

        let generation = try await env.generator.generate(request())
        let briefID = try XCTUnwrap(generation.brief.id)
        let playlistID = try await env.generator.saveAsPlaylist(title: "Dinner Set")

        let playlist = try await env.pool.read { db in
            try DJPlaylist.fetchOne(db, key: playlistID)
        }
        XCTAssertEqual(playlist?.title, "Dinner Set")
        XCTAssertEqual(playlist?.kind, "manual")
        let storedItems = try await env.pool.read { db in
            try DJPlaylistItem.filter(Column("playlistID") == playlistID)
                .order(Column("position")).fetchAll(db)
        }
        XCTAssertEqual(storedItems.map(\.trackID), generation.items.map(\.trackID))
        let linked = try await env.pool.read { db in
            try AutoPlaylistResult.filter(Column("briefID") == briefID).fetchOne(db)
        }
        XCTAssertEqual(linked?.playlistID, playlistID)
    }

    // MARK: - Byte-exact constraintsJSON (NFR-DET-3)

    func testConstraintsJSONRoundTripsByteExact() throws {
        let constraints = SequencingConstraints(minArtistGap: 3,
                                                minAlbumGap: 2,
                                                maxBPMJump: 6.5,
                                                keyStrictness: 0.8,
                                                allowExplicit: false,
                                                requireCached: true,
                                                bpmRange: 118...128,
                                                excludeGenres: ["House"])
        let encoded = try constraints.encodedJSONString()
        let decoded = try SequencingConstraints.decodeJSON(encoded)
        XCTAssertEqual(decoded, constraints)
        XCTAssertEqual(try decoded.encodedJSONString(), encoded,
                       "encode → decode → encode is byte-identical")
    }

    func testGeneratorPersistsCanonicalConstraints() async throws {
        let env = try await makeEnvironment(trackCount: 20)
        defer { try? env.pool.close() }

        let constraints = SequencingConstraints(bpmRange: 100...130)
        let generation = try await env.generator.generate(request(constraints: constraints))
        XCTAssertEqual(generation.brief.constraints, constraints)
        let briefID = try XCTUnwrap(generation.brief.id)
        let reloaded = try XCTUnwrap(try AutoPlaylistRepository(pool: env.pool)
            .brief(id: briefID))
        XCTAssertEqual(reloaded.constraintsJSON, generation.brief.constraintsJSON)
    }

    // MARK: - Sync mapping (§2.9)

    func testAutoPlaylistBriefPayloadRoundTripsByteExact() throws {
        let constraints = try SequencingConstraints(minArtistGap: 3, bpmRange: 118...128)
            .encodedJSONString()
        let brief = AutoPlaylistBrief(syncID: "SYNC-1",
                                      prompt: "wind down the night",
                                      arcKind: "windDown",
                                      arcPointsJSON: "{}",
                                      targetSeconds: 5400,
                                      targetTrackCount: nil,
                                      constraintsJSON: constraints,
                                      seedTrackID: 12,
                                      seedCrateID: nil,
                                      randomSeed: 0xDEAD_BEEF,
                                      createdAt: Date(timeIntervalSince1970: 0),
                                      updatedAt: Date(timeIntervalSince1970: 0))

        let payload = AutoPlaylistBriefMapping.payload(from: brief)
        XCTAssertEqual(AutoPlaylistBriefMapping.recordName(syncID: brief.syncID),
                       "AutoPlaylistBrief-SYNC-1")

        let data = try AutoPlaylistBriefMapping.encode(payload)
        let decoded = try AutoPlaylistBriefMapping.decode(data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(try AutoPlaylistBriefMapping.encode(decoded), data,
                       "payload encode → decode → encode is byte-identical")

        // Row → payload → row is identity (ignoring id/timestamps).
        let rebuilt = AutoPlaylistBriefMapping.brief(from: payload, id: brief.id,
                                                     createdAt: brief.createdAt,
                                                     updatedAt: brief.updatedAt)
        XCTAssertEqual(rebuilt, brief)
    }
}
