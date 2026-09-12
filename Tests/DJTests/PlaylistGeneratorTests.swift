import XCTest
import GRDB
import ParsoAudioAnalysis
import ParsoAudioNeural

@testable import TonearmCore
@testable import TonearmDJ
@testable import TonearmDiscovery

/// PlaylistGenerator + AutoPlaylistRepository (plan §3.3): brief→sequence→
/// persist atomicity, rejection exclusion, locks honoured on regenerate, the
/// honest short-pool state, and the byte-exact `constraintsJSON` / sync-mapping
/// round-trips.
///
/// C02 (IMPLEMENT_CLAP_PLAN.md, Slice B): rewired off the deleted DJ-local
/// `VectorStore`/`DJTrack`/`CLAPEmbedder` pipeline onto the unified
/// `SearchService`/`DiscoverySearchQuery` engine (the same one
/// `VibeSearchModel`/`SmartCrateRepository` use in production) — every fixture
/// track is now a REAL core `LibraryStore`-imported track, not a DJ-local
/// `DJTrack` row, per session 14/15's explicit finding that DJ-local fixtures
/// hid real core/DJ-local id bugs before. `auto_playlist_brief/result/item`
/// themselves stay DJ-local (unchanged persistence).
final class PlaylistGeneratorTests: XCTestCase {

    private let storeDims = 32

    // MARK: - Environment

    private func makeSpec() -> EmbeddingModelSpec {
        var spec = EmbeddingModelSpec.musicCLAPMetadata
        spec.dimensions = storeDims
        return spec
    }

    private struct Environment {
        var djPool: DatabasePool
        var core: LibraryStore
        var generator: PlaylistGenerator
        var trackIDs: [Int64]
    }

    private func makeEnvironment(trackCount: Int) async throws -> Environment {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistGeneratorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let djPool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))

        let core = try LibraryStore(inMemory: true)
        let writer = await core.dbQueue
        let models = ModelManager(resourceProvider: { .unavailable })
        await models.injectModelForTesting(DeterministicFakeSemanticModel(spec: makeSpec()))
        let cacheURL = dir.appendingPathComponent("vectors.bin")
        let searchService = SearchService(writer: writer,
                                          index: VectorIndex(writer: writer, cacheURL: cacheURL),
                                          models: models)
        let generator = PlaylistGenerator(pool: djPool, library: core, searchService: searchService)

        let source = try await core.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Fixture",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))

        var trackIDs: [Int64] = []
        for index in 0..<trackCount {
            let id = try await seedTrack(index: index, core: core, sourceID: source.id!, dims: storeDims)
            trackIDs.append(id)
        }
        return Environment(djPool: djPool, core: core, generator: generator, trackIDs: trackIDs)
    }

    /// One real core track: `track` (bpm-free — bpm/camelot/energy live in
    /// `discovery_track_analysis`), an `asset`, and a `discovery_embedding` row
    /// with a deterministic pseudo-embedding (SHA-256-seeded, same primitive
    /// production's `DeterministicFakeSemanticModel` uses for text).
    @discardableResult
    private func seedTrack(index: Int, core: LibraryStore, sourceID: Int64, dims: Int) async throws
        -> Int64 {
        let track = try await core.insertTrack(Track(
            id: nil, albumId: nil, sourceId: sourceID, title: "Track \(index)", trackNo: nil,
            discNo: nil, durationSec: 180 + Double((index % 12) * 20), codec: "WAV",
            sampleRate: 44_100, bitDepthOrBitrate: nil, sortKey: "track-\(String(format: "%04d", index))"))
        let trackID = try XCTUnwrap(track.id)
        let asset = try await core.insertAsset(Asset(
            id: nil, trackId: trackID, kind: .localRef, bookmark: nil,
            relPath: "track-\(index).wav", remoteURL: nil, altRemoteURL: nil, sizeBytes: nil,
            unsupportedReason: nil))
        let assetID = try XCTUnwrap(asset.id)

        let writer = await core.dbQueue
        try await writer.write { db in
            var analysis = DiscoveryTrackAnalysis(
                trackId: trackID, assetId: assetID, assetRevision: 1,
                analysisVersion: DiscoveryPipelineVersion.musicalAnalysis,
                bpm: 110 + Double(index % 40),
                key: "\((index % 12) + 1)\(index % 2 == 0 ? "A" : "B")",
                energy: Double(index % 10), phraseSummary: nil,
                analysisScopeSeconds: nil, completedAt: Date())
            try analysis.insert(db)

            let vector = DeterministicFakeSemanticModel.pseudoEmbedding(
                from: Data("seed phrase \(index)".utf8), seed: Data("fake-clap-v1".utf8), dims: dims)
            let (int8, scale) = VectorQuantization.quantize(vector)
            var embedding = DiscoveryEmbedding(
                trackId: trackID, assetId: assetID, assetRevision: 1,
                modelVersion: DiscoveryPipelineVersion.model,
                preprocessingVersion: DiscoveryPipelineVersion.preprocessing,
                samplingVersion: DiscoveryPipelineVersion.sampling,
                dimensions: dims, quantizedVector: VectorQuantization.data(int8),
                scale: Double(scale), completedAt: Date())
            try embedding.upsert(db)
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
        defer { try? env.djPool.close() }

        let generation = try await env.generator.generate(request())

        // Brief persisted with the request's fields.
        let briefID = try XCTUnwrap(generation.brief.id)
        XCTAssertEqual(generation.brief.arcKind, "build")
        XCTAssertEqual(generation.brief.prompt, "rainy sunday dinner")
        XCTAssertNotNil(try AutoPlaylistRepository(pool: env.djPool).brief(id: briefID))

        // Result persisted, items in order, no duplicates, positions dense.
        XCTAssertNotNil(generation.result.id)
        XCTAssertEqual(generation.items.map(\.position), Array(0..<generation.items.count))
        let ids = generation.items.map(\.trackID)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(ids.allSatisfy { env.trackIDs.contains($0) },
                      "every generated track is a real core track id")

        // The repository reloads the brief's latest result with its items.
        let latest = try XCTUnwrap(try AutoPlaylistRepository(pool: env.djPool)
            .latestResult(for: briefID))
        XCTAssertEqual(latest.items.map(\.trackID), ids)
        XCTAssertEqual(latest.result.totalSeconds, generation.result.totalSeconds)
        XCTAssertEqual(latest.result.analysisVersion, AnalysisVersions.embedding)
    }

    func testGenerationIsDeterministicForSameSeed() async throws {
        let env = try await makeEnvironment(trackCount: 40)
        defer { try? env.djPool.close() }

        let first = try await env.generator.generate(request(randomSeed: 0x1234))
        let second = try await env.generator.generate(request(randomSeed: 0x1234))
        XCTAssertEqual(first.items.map(\.trackID), second.items.map(\.trackID),
                       "same brief + seed + library ⇒ byte-identical sequence (NFR-DET-1)")
    }

    // MARK: - Persist atomicity (NFR-REL-1)

    /// `auto_playlist_item.trackID` no longer FKs into the DJ-local `track`
    /// table (dj_v10 — it holds a *core* id now), so an "orphan track id" can
    /// no longer be the failure trigger here. A duplicate explicit primary
    /// key is a real, still-enforced constraint violation that lands in the
    /// same place (the items loop, after brief + result already inserted in
    /// the same transaction) and proves the same thing: the whole write rolls
    /// back, not just the failing row.
    func testPersistRollsBackAtomicallyOnFailedItemInsert() async throws {
        let env = try await makeEnvironment(trackCount: 4)
        defer { try? env.djPool.close() }
        let repository = AutoPlaylistRepository(pool: env.djPool)
        let brief = AutoPlaylistBrief(syncID: "B-\(UUID().uuidString)", prompt: "x",
                                      arcKind: "build",
                                      constraintsJSON: try SequencingConstraints().encodedJSONString(),
                                      randomSeed: 1, createdAt: Date(), updatedAt: Date())
        let result = AutoPlaylistResult(briefID: 0, generatedAt: Date(), totalSeconds: 1,
                                        arcError: 0, meanTransitionCost: 0, analysisVersion: 1)
        let good = AutoPlaylistItem(id: 555, resultID: 0, trackID: env.trackIDs[0], position: 0,
                                    targetEnergy: 0.5, actualEnergy: 0.5,
                                    transitionCostIn: 0, semanticScore: 0.5)
        let duplicateID = AutoPlaylistItem(id: 555, resultID: 0, trackID: env.trackIDs[1], position: 1,
                                           targetEnergy: 0.5, actualEnergy: 0.5,
                                           transitionCostIn: 0, semanticScore: 0.5)
        XCTAssertThrowsError(try repository.save(brief: brief, result: result,
                                                 items: [good, duplicateID]))
        let briefCount = try await env.djPool.read { try AutoPlaylistBrief.fetchCount($0) }
        let resultCount = try await env.djPool.read { try AutoPlaylistResult.fetchCount($0) }
        XCTAssertEqual(briefCount, 0, "failed save left no brief")
        XCTAssertEqual(resultCount, 0, "failed save left no result")
    }

    // MARK: - Rejection exclusion (§28A.4)

    func testRejectedTrackIsExcludedOnRegenerate() async throws {
        let env = try await makeEnvironment(trackCount: 30)
        defer { try? env.djPool.close() }

        let first = try await env.generator.generate(request())
        let rejected = first.items[3].trackID
        let briefID = try XCTUnwrap(first.brief.id)

        let second = try await env.generator.reject(trackID: rejected)

        XCTAssertFalse(second.items.map(\.trackID).contains(rejected),
                       "rejected track re-appeared after reject + re-run")
        XCTAssertTrue(try AutoPlaylistRepository(pool: env.djPool)
            .rejections(for: briefID).contains(rejected))
    }

    // MARK: - Locks honoured on regenerate (FR-PLIST-6)

    func testLocksAreHonouredOnGenerateAndRegenerate() async throws {
        let env = try await makeEnvironment(trackCount: 30)
        defer { try? env.djPool.close() }

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
        defer { try? env.djPool.close() }

        let seedID = env.trackIDs[7]
        let generation = try await env.generator.generate(
            request(prompt: "", seedTrackID: seedID))

        XCTAssertEqual(generation.items[0].trackID, seedID, "seed track opens the playlist")
        XCTAssertEqual(generation.items.filter { $0.trackID == seedID }.count, 1,
                       "seed track appears nowhere else")
    }

    /// A seed id with no stored embedding falls through to the prompt anchor
    /// instead of throwing — same fallback chain the old pipeline had, now
    /// gated on a real `discovery_embedding` existence check.
    func testSeedTrackWithoutEmbeddingFallsBackToPrompt() async throws {
        let env = try await makeEnvironment(trackCount: 10)
        defer { try? env.djPool.close() }
        let source = try await env.core.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Fixture 2",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let unindexed = try await env.core.insertTrack(Track(
            id: nil, albumId: nil, sourceId: source.id!, title: "No embedding", trackNo: nil,
            discNo: nil, durationSec: 200, codec: "WAV", sampleRate: 44_100,
            bitDepthOrBitrate: nil, sortKey: "unindexed"))

        let generation = try await env.generator.generate(
            request(seedTrackID: unindexed.id!))
        XCTAssertFalse(generation.items.map(\.trackID).contains(unindexed.id!),
                       "an unindexed seed never appears — it isn't the anchor and isn't a candidate")
    }

    // MARK: - Filter-only (fixes "filter-only rejected")

    func testBPMOnlyBriefWithNoTextIsAValidAnchor() async throws {
        let env = try await makeEnvironment(trackCount: 30)
        defer { try? env.djPool.close() }

        let generation = try await env.generator.generate(
            request(prompt: "", constraints: SequencingConstraints(bpmRange: 110...115)))
        XCTAssertFalse(generation.items.isEmpty,
                       "a BPM-only brief with no text/seed/crate must not throw .noAnchor")
    }

    // MARK: - Honest short pool (plan §2.7)

    func testShortPoolGeneratesWhatIsPossibleAndSaysSo() async throws {
        let env = try await makeEnvironment(trackCount: 5)
        defer { try? env.djPool.close() }

        let generation = try await env.generator.generate(
            request(targetTrackCount: 20))
        XCTAssertEqual(generation.requestedCount, 20)
        XCTAssertEqual(generation.candidateCount, 5)
        XCTAssertTrue(generation.isShortPool, "pool is short — must say so, never pad")
        XCTAssertEqual(generation.items.count, 5, "generates what is possible")
    }

    func testNoAnchorWhenNothingToSearchFor() async throws {
        let env = try await makeEnvironment(trackCount: 5)
        defer { try? env.djPool.close() }
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
        defer { try? env.djPool.close() }

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
        defer { try? env.djPool.close() }

        let first = try await env.generator.generate(request(targetSeconds: 1800))
        let second = try await env.generator.extend(minutes: 30)
        XCTAssertEqual(second.brief.targetSeconds, 1800 + 30 * 60)
        XCTAssertGreaterThanOrEqual(second.items.count, first.items.count,
                                    "extending grows the sequence")
    }

    func testReshuffleKeepsEndpointsFixed() async throws {
        let env = try await makeEnvironment(trackCount: 40)
        defer { try? env.djPool.close() }

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
        defer { try? env.djPool.close() }

        let generation = try await env.generator.generate(request())
        let briefID = try XCTUnwrap(generation.brief.id)
        let playlistID = try await env.generator.saveAsPlaylist(title: "Dinner Set")

        let playlist = try await env.djPool.read { db in
            try DJPlaylist.fetchOne(db, key: playlistID)
        }
        XCTAssertEqual(playlist?.title, "Dinner Set")
        XCTAssertEqual(playlist?.kind, "manual")
        let storedItems = try await env.djPool.read { db in
            try DJPlaylistItem.filter(Column("playlistID") == playlistID)
                .order(Column("position")).fetchAll(db)
        }
        XCTAssertEqual(storedItems.map(\.trackID), generation.items.map(\.trackID))
        let linked = try await env.djPool.read { db in
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
        defer { try? env.djPool.close() }

        let constraints = SequencingConstraints(bpmRange: 100...130)
        let generation = try await env.generator.generate(request(constraints: constraints))
        XCTAssertEqual(generation.brief.constraints, constraints)
        let briefID = try XCTUnwrap(generation.brief.id)
        let reloaded = try XCTUnwrap(try AutoPlaylistRepository(pool: env.djPool)
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
