#if !os(watchOS)
import XCTest
@testable import TonearmCore

/// Card → request → AudioPlayer → streaming decks → renderer, with procedural sources standing in for
/// the release's byte ranges (everything else is the shipping code).
@MainActor
final class StarterBlendProductionPathTests: XCTestCase {
    private var directory: URL!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tonearm-starter-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        PlaybackStateFileStore.fileURLOverride = directory.appendingPathComponent("playback-state.v2.json")
        suite = "test.starter.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        PlaybackStateStore.defaultsProvider = { defaults }
        reset()
    }

    override func tearDown() async throws {
        reset()
        PlaybackStateStore.defaultsProvider = { PlaybackStateStore.sharedDefaults() }
        PlaybackStateFileStore.fileURLOverride = nil
        try? FileManager.default.removeItem(at: directory)
        UserDefaults().removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func reset() {
        let player = AudioPlayer.shared
        player.keepPlayingEnabled = false
        player.keepPlayingProvider = nil
        player.keepPlayingExtensionTask?.cancel()
        player.endStarterSession()
        player.starterSourceFactoryOverride = nil
        player.starterStatusHandler = nil
        player.resetRestoreForTesting()
        if !player.queue.isEmpty { player.removeFromQueue(atOffsets: IndexSet(0..<player.queue.count)) }
        player.repeatMode = .off
        player.shuffle = false
    }

    private func wait(_ stream: () -> StarterStreamPlayer?, timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                let snap = stream()?.snapshot()
                let message = "timed out; snapshot \(String(describing: snap)) index \(AudioPlayer.shared.index)"
                XCTFail(message)
                throw NSError(domain: "StarterTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            try await Task.sleep(nanoseconds: 1_000_000)
            stream()?.tick()
        }
    }

    /// Renders until the stream hands over to track `index` (or `limit` frames pass).
    private func render(until index: Int, player: AudioPlayer, limit: Int = 44_100 * 70) async throws {
        var rendered = 0
        while player.index < index, rendered < limit, let stream = player.starterStream {
            let cell = try XCTUnwrap(stream.cell)
            let pending: BoundedOverlapPlan? = cell.perform { if case .pending(let p) = $0.overlap { return p }; return nil }
            if let pending, let trigger = pending.outgoingTriggerFrame,
               cell.perform({ $0.decks[$0.main].positionFrame }) + 4_096 >= trigger {
                try await wait({ stream }) { cell.perform { $0.decks[$0.incomingIndex].bufferedFrames } >= pending.minIncomingBufferedFrames + 4_096 }
            }
            let main = cell.perform { $0.main }
            try await wait({ stream }) { stream.bufferedFrames(deck: main) >= 4_096 || player.index >= index }
            if player.index >= index { break }
            _ = stream.renderOffline(frames: 512)
            rendered += 512
            if (rendered / 512) % 4 == 0 { stream.tick(); await Task.yield() }
        }
        player.starterStream?.tick()
    }

    private func start(_ blend: StarterBlend, factory: SynthCatalog.Factory) async throws -> AudioPlayer {
        let player = AudioPlayer.shared
        player.starterSourceFactoryOverride = factory.make
        let playback = StarterBlendPlayback(start: { player.playStarterBlend($0) })
        await playback.play(blend)
        return player
    }

    func testStartingABlendStreamsOnTheBoundedDecksNotTheResidentOnes() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let factory = SynthCatalog.Factory(blend)
        var statuses: [StarterStreamStatus] = []
        AudioPlayer.shared.starterStatusHandler = { statuses.append($0) }
        let player = try await start(blend, factory: factory)
        XCTAssertEqual(player.activeStarterBlendID, blend.id)
        XCTAssertNotNil(player.starterStream)
        XCTAssertNil(player.mixDecks, "Starter Blends never use the resident whole-track decks")
        XCTAssertFalse(player.wantsMixDecks)
        XCTAssertEqual(player.queue.count, 6)
        XCTAssertEqual(statuses.first, .buffering(blendID: blend.id))
        try await wait({ player.starterStream }) { statuses.contains(.blending(blendID: blend.id)) }
        XCTAssertGreaterThanOrEqual(player.starterStream?.bufferedFrames(deck: 0) ?? 0, 44_100, "started after ordinary buffering")
        XCTAssertTrue(player.isPlaying)
    }

    func testAllFiveEdgesAreConcreteAndReadyAsSoonAsTheBlendIsLoaded() async throws {
        let blend = StarterBlendCatalog.blends[1]
        let player = try await start(blend, factory: SynthCatalog.Factory(blend))
        for i in 0..<5 {
            let key = TransitionEdgeKey(from: player.queueOccurrences[i], to: player.queueOccurrences[i + 1])
            let snapshot = try XCTUnwrap(player.transitionExecution.snapshot(for: key), "edge \(i + 1)")
            let style = AudioPlayer.displayStyle(blend.edgePlans[i].style)
            XCTAssertEqual(snapshot.plannedStyle, style)
            XCTAssertEqual(snapshot.executedStyle, style)
            XCTAssertEqual(snapshot.readiness, .ready)
            XCTAssertNil(snapshot.reason, "no fallback reason")
        }
    }

    func testPlannedEdgeIsExecutedAndPublishedThroughTheProductionPlayer() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let factory = SynthCatalog.Factory(blend)
        let player = try await start(blend, factory: factory)
        let stream = try XCTUnwrap(player.starterStream)
        let plan = blend.edgePlans[0]
        try await wait({ stream }) { !stream.isBuffering }
        // Jump the controller to just before the supplied overlap (what a listener's seek does).
        player.seek(to: (plan.blendStartSeconds ?? 0) - 3)
        try await wait({ stream }) { stream.cell?.perform { if case .pending = $0.overlap { return true }; return false } ?? false }
        try await render(until: 1, player: player)
        XCTAssertEqual(player.index, 1, "the stream advanced the queue at the planned handoff")
        let key = TransitionEdgeKey(from: player.queueOccurrences[0], to: player.queueOccurrences[1])
        let snapshot = try XCTUnwrap(player.transitionExecution.snapshot(for: key))
        XCTAssertEqual(snapshot.executedStyle, .bassSwap)
        XCTAssertTrue(snapshot.isTerminal || snapshot.phase == .handedOff)
        XCTAssertNotNil(snapshot.handoffFrame)
        // Starter definitions carry no per-track facts, so the row's duration is whatever the catalog supplied (none here).
        XCTAssertEqual(player.duration, player.queue[1].track.durationSec ?? 0, accuracy: 0.01)
    }

    /// Drives every supplied edge of every blend through the production player and bounded renderer.
    func testAllThirtySuppliedEdgesExecuteThroughTheProductionRenderer() async throws {
        var executed = 0
        for blend in StarterBlendCatalog.blends {
            for i in 0..<5 {
                reset()
                let plan = blend.edgePlans[i]
                let label = "\(blend.id) edge \(plan.edge)"
                let schedule = try XCTUnwrap(plan.schedule(), label)
                let player = try await start(blend, factory: SynthCatalog.Factory(blend))
                let stream = try XCTUnwrap(player.starterStream, label)
                let key = TransitionEdgeKey(from: player.queueOccurrences[i], to: player.queueOccurrences[i + 1])
                let planned = try XCTUnwrap(player.transitionExecution.snapshot(for: key), label)
                XCTAssertEqual(planned.plannedStyle, AudioPlayer.displayStyle(plan.style), label)
                XCTAssertEqual(planned.executedStyle, AudioPlayer.displayStyle(plan.style), "\(label): no synthetic re-plan")
                if i > 0 { player.skipToIndex(i) }
                try await wait({ stream }) { !stream.isBuffering }
                player.seek(to: max(0, schedule.outgoingStart - 3))
                try await wait({ stream }) { stream.cell?.perform { if case .pending = $0.overlap { return true }; return false } ?? false }
                do { try await render(until: i + 1, player: player) } catch { XCTFail("\(label) \(schedule)"); throw error }
                XCTAssertEqual(player.index, i + 1, label)
                let snapshot = try XCTUnwrap(player.transitionExecution.snapshot(for: key), label)
                XCTAssertEqual(snapshot.plannedStyle, AudioPlayer.displayStyle(plan.style), label)
                XCTAssertEqual(snapshot.executedStyle, AudioPlayer.displayStyle(plan.style), label)
                XCTAssertNotNil(snapshot.handoffFrame, label)
                XCTAssertNil(snapshot.reason, label)
                executed += 1
            }
        }
        XCTAssertEqual(executed, 30)
        let night = try XCTUnwrap(StarterBlendRuntimeData.edges.first { $0.blendID == "starter.night-drive" && $0.edge == 5 })
        XCTAssertEqual(night.schedule()?.outgoingStart, 17.481796056227534)
        XCTAssertEqual(night.schedule()?.incomingStart, 0)
        let rainy = try XCTUnwrap(StarterBlendRuntimeData.edges.first { $0.blendID == "starter.rainy-day" && $0.edge == 1 })
        XCTAssertEqual(rainy.schedule()?.outgoingStart, 83.738989863914227)
        XCTAssertEqual(rainy.schedule()?.incomingStart, 0.401727281007933)
    }

    func testIncompleteLegacyPlanFallsBackTruthfullyWithoutReplanning() async throws {
        let blend = StarterBlendCatalog.blends[0]
        var legacy = blend.document
        legacy.edges[1].plan?.blendEndSeconds = nil
        let request = try XCTUnwrap(BlendReplay.starterRequest(for: legacy))
        XCTAssertNil(request.edgePlans[1].schedule(), "an incomplete plan is never completed from audio or a fact table")
        var statuses: [StarterStreamStatus] = []
        let player = AudioPlayer.shared
        player.starterStatusHandler = { statuses.append($0) }
        player.starterSourceFactoryOverride = SynthCatalog.Factory(blend).make
        player.playStarterBlend(request)
        XCTAssertNil(player.starterStream)
        XCTAssertNil(player.mixDecks)
        XCTAssertTrue(player.transitionExecution.liveSnapshots.isEmpty, "no edge claims a blend")
        guard case .sequential(_, let reason, let canRetry)? = statuses.last else { return XCTFail("\(statuses)") }
        XCTAssertEqual(reason, "This blend's transition plan is incomplete.")
        XCTAssertFalse(canRetry)
        player.pause()
    }

    func testStarterDefinitionsHaveNoDuplicateTrackFactsOrOldScheduleSignature() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for banned in ["StarterBlendRuntimeData.tracks", "StarterBlendPack.trackFacts", "schedule(outgoing:", ".schedule(outgoing"] {
                XCTAssertFalse(text.contains(banned), "\(url.lastPathComponent) must not contain \(banned)")
            }
        }
    }

    func testUnavailableAssetFallsBackToSequentialWithoutClaimingABlend() async throws {
        for (error, retryable) in [(ReleaseRangeError.permanent("not found (HTTP 404)"), false),
                                   (ReleaseRangeError.transient("offline"), true)] {
            reset()
            let blend = StarterBlendCatalog.blends[0]
            let factory = SynthCatalog.Factory(blend)
            factory.failing[blend.trackIDs[2]] = error
            var statuses: [StarterStreamStatus] = []
            AudioPlayer.shared.starterStatusHandler = { statuses.append($0) }
            let player = try await start(blend, factory: factory)
            player.skipToIndex(2)
            try await wait({ player.starterStream }) { player.starterStream == nil && statuses.contains { if case .sequential = $0 { return true }; return false } }
            guard case .sequential(let id, let reason, let canRetry)? = statuses.last else { return XCTFail("\(statuses)") }
            XCTAssertEqual(id, blend.id)
            XCTAssertEqual(canRetry, retryable)
            XCTAssertTrue(reason.hasPrefix("Track 3:"), reason)
            XCTAssertNil(player.starterStream)
            XCTAssertNil(player.mixDecks)
            XCTAssertEqual(player.index, 2, "plays the unavailable track's slot in order")
            XCTAssertTrue(player.transitionExecution.liveSnapshots.isEmpty, "no edge claims a blend")
            XCTAssertFalse(statuses.contains(.blending(blendID: blend.id)) && statuses.last == .blending(blendID: blend.id))
            player.pause()
        }
    }

    func testSavedBlendReplaysWithItsPackAndPlans() async throws {
        let blend = StarterBlendCatalog.blends[3]
        let repo = BlendRepository(url: directory.appendingPathComponent("blends.json"))
        try await repo.save(blend.document)
        let fresh = BlendRepository(url: directory.appendingPathComponent("blends.json"))
        let found = await fresh.blend(id: blend.document.id)
        let saved = try XCTUnwrap(found)
        XCTAssertEqual(saved.pack, .v1)
        XCTAssertEqual(saved.edges.compactMap(\.plan), blend.edgePlans)
        let request = try XCTUnwrap(BlendReplay.starterRequest(for: saved))
        XCTAssertEqual(request.edgePlans, blend.edgePlans)
        XCTAssertEqual(request.edgePlans.compactMap { $0.schedule() }.count, 5)
        XCTAssertEqual(request.trackIDs, blend.trackIDs)
        XCTAssertEqual(request.pack, StarterBlendPack.v1)
        XCTAssertEqual(request.blendID, blend.id)
        let expected = try StarterBlendPlayback.catalogRows(for: blend)
        XCTAssertEqual(request.rows.map(\.track.title), expected.map(\.track.title))
        XCTAssertEqual(request.rows.compactMap(\.artist?.name), expected.compactMap(\.artist?.name))
        XCTAssertEqual(Set(request.rows.compactMap(\.album?.title)), [blend.title])
        XCTAssertFalse(request.rows.contains { $0.track.title == "\(blend.title) \($0.track.trackNo ?? 0)" })

        let player = AudioPlayer.shared
        player.starterSourceFactoryOverride = SynthCatalog.Factory(blend).make
        player.playStarterBlend(request)
        XCTAssertEqual(player.activeStarterBlendID, blend.id)
        XCTAssertEqual(player.starterSession?.plans, blend.edgePlans, "the persisted plans reach the renderer's session")
        XCTAssertEqual(player.starterSession?.pack, .v1)
        XCTAssertNil(player.mixDecks)
        XCTAssertEqual(player.queue.map(\.track.title), expected.map(\.track.title))
        XCTAssertEqual(player.queue.compactMap(\.artist?.name), expected.compactMap(\.artist?.name))
        XCTAssertEqual(player.queue.first?.album?.title, blend.title)
    }

    func testDocumentWithoutPlansDoesNotReplayAsABlend() {
        var doc = StarterBlendCatalog.blends[0].document
        doc.edges[2].plan = nil
        XCTAssertNil(BlendReplay.starterRequest(for: doc))
        doc = StarterBlendCatalog.blends[0].document
        doc.pack = nil
        XCTAssertNil(BlendReplay.starterRequest(for: doc))
    }

    /// Indexes every seeded Starter row through the store's own lifecycle API (`markBlendEligible`), keeping the
    /// catalog's genuine genre / key / source; only the beat grid (which the catalog lacks) comes from the fixture.
    /// No seeded row's genre, key or tempo is ever rewritten to manufacture compatibility.
    private func indexSeededCatalog() async throws {
        let store = LibraryStore.shared
        let rows = try await store.blendCatalogTracks(atLeast: .unindexed, packTag: StarterBlendPack.v1.releaseTag)
        for row in rows where row.state == .unindexed {
            guard let traits = row.traits, let fixture = StarterTestFacts.byID[row.trackID] else { continue }
            let facts = StarterTrackFacts(id: row.trackID, durationSeconds: row.durationSeconds ?? fixture.durationSeconds,
                                          bpm: row.bpm ?? fixture.bpm, beatPeriod: fixture.beatPeriod,
                                          beatPhase: fixture.beatPhase, rmsDB: fixture.rmsDB)
            try await store.markBlendEligible(key: row.catalogKey, facts: facts, traits: traits)
        }
    }

    private nonisolated static func metadata(_ id: String, genre: String, duration: Double) -> CatalogPlaybackMetadata {
        CatalogPlaybackMetadata(trackID: id, title: "Jamendo \(id)", artist: "Artist \(id)", genre: genre,
                                artworkURL: nil, durationSeconds: duration)
    }

    /// A genuine ordinary Jamendo catalog row, indexed through the lifecycle API as analysis would store it:
    /// compatible traits and a tempo/beat grid close to the tail's own. Returns its stable track ID.
    private func indexJamendoFollower(id: String, tail: BlendCatalogTrack, key: String? = nil, bpmScale: Double = 1,
                                      subgenre: String? = nil, index: Bool = true) async throws {
        let store = LibraryStore.shared
        try await store.registerJamendoCatalogTrack(trackID: id)
        guard index else { return }
        let tailTraits = try XCTUnwrap(tail.traits), tailFacts = try XCTUnwrap(tail.facts)
        let traits = BlendTraits(genre: tailTraits.genre, subgenre: subgenre ?? tailTraits.subgenre,
                                 camelotKey: key ?? tailTraits.camelotKey)
        let facts = StarterTrackFacts(id: id, durationSeconds: 240, bpm: tailFacts.bpm * bpmScale,
                                      beatPeriod: tailFacts.beatPeriod / bpmScale, beatPhase: 0.2, rmsDB: tailFacts.rmsDB)
        try await store.markBlendEligible(key: BlendCatalogTrack.jamendoKey(trackID: id), facts: facts, traits: traits)
    }

    private func startForKeepPlaying(_ blend: StarterBlend, jamendo ids: [String: Double] = [:]) async throws -> AudioPlayer {
        let player = try await start(blend, factory: SynthCatalog.Factory(blend))
        player.keepPlayingMetadataResolver = { requested in
            try requested.map { id in
                if let duration = ids[id] { return Self.metadata(id, genre: "Electronic", duration: duration) }
                guard let found = try StarterBlendPlayback.bundledResolver([id]).first else { throw StarterCatalogError.missing([id]) }
                return found
            }
        }
        struct Forbidden: KeepPlayingSimilarityProviding {
            func continuationTrackIDs(after recentlyPlayed: [Int64], excluding: Set<Int64>,
                                      matchingTracksOnly: Bool, limit: Int) async -> KeepPlayingLookup {
                XCTFail("Keep Playing consulted the similarity model for a Starter Blend")
                return .unavailable
            }
        }
        player.keepPlayingProvider = Forbidden()
        player.keepPlayingEnabled = true
        return player
    }

    func testKeepPlayingAppendsARealJamendoCatalogRowAndPersistsItsEdge() async throws {
        let blend = StarterBlendCatalog.blends[1]
        try await indexSeededCatalog()
        let store = LibraryStore.shared
        let tailKey = BlendCatalogTrack.key(pack: .v1, trackID: try XCTUnwrap(blend.trackIDs.last))
        let tailOpt = try await store.blendCatalogTrack(key: tailKey)
        let tail = try XCTUnwrap(tailOpt)
        let id = "9900001"
        try await indexJamendoFollower(id: id, tail: tail)
        let beforeOpt = try await store.blendCatalogTrack(key: BlendCatalogTrack.jamendoKey(trackID: id))
        let before = try XCTUnwrap(beforeOpt)
        let locator = try XCTUnwrap(before.keepPlayingLocator(in: .v1))
        XCTAssertEqual(locator, .jamendo(trackID: id, cachedURL: nil, expiry: nil))
        let player = try await startForKeepPlaying(blend, jamendo: [id: 240])
        await player.extendKeepPlayingQueueForTesting()
        let session = try XCTUnwrap(player.starterSession)
        XCTAssertFalse(player.keepPlayingLastExtensionWasFallback)
        XCTAssertEqual(session.trackIDs.last, id, "the ordinary Jamendo row was appended")
        XCTAssertEqual(session.plans.count, session.trackIDs.count - 1)
        XCTAssertTrue(session.isExecutable)
        XCTAssertEqual(player.queue.count, session.trackIDs.count)
        XCTAssertNil(player.queue.last?.asset?.remoteURL, "no URL is forged for a Jamendo row without a cached one")
        // The concrete edge is persisted, both rows advanced, and it replays from the store alone.
        let joining = try XCTUnwrap(session.plans.last)
        XCTAssertEqual(joining.outgoingTrackID, blend.trackIDs.last)
        XCTAssertEqual(joining.incomingTrackID, id)
        let stored = try await store.blendCatalogEdgePlan(from: tailKey, to: BlendCatalogTrack.jamendoKey(trackID: id))
        XCTAssertEqual(stored, joining)
        let afterOpt = try await store.blendCatalogTrack(key: BlendCatalogTrack.jamendoKey(trackID: id))
        let after = try XCTUnwrap(afterOpt)
        XCTAssertEqual(after.state, .edgePlanned)
        var unchanged = after; unchanged.state = before.state; unchanged.updatedAt = before.updatedAt
        XCTAssertEqual(unchanged, before, "selection changed no canonical metadata")
        var replay = StarterSession(StarterPlayRequest(blendID: blend.id, occurrenceIDs: [], rows: Array(player.queue.prefix(blend.trackIDs.count)),
                                                       trackIDs: blend.trackIDs, edgePlans: blend.edgePlans))
        replay.append(trackIDs: [id], plans: [try XCTUnwrap(stored)], rowIDs: [player.queue.last?.track.id])
        XCTAssertTrue(replay.isExecutable)
    }

    func testKeepPlayingRejectsIneligibleJamendoRowsAndFallsBackTruthfully() async throws {
        let blend = StarterBlendCatalog.blends[2]
        try await indexSeededCatalog()
        let store = LibraryStore.shared
        let tailOpt = try await store.blendCatalogTrack(
            key: BlendCatalogTrack.key(pack: .v1, trackID: try XCTUnwrap(blend.trackIDs.last)))
        let tail = try XCTUnwrap(tailOpt)
        let tailKey = try XCTUnwrap(tail.traits).camelotKey
        let number = try XCTUnwrap(BlendTraits.parseCamelot(tailKey)).number
        let farKey = "\((number + 3) % 12 + 1)\(tailKey.hasSuffix("A") ? "B" : "A")"
        try await indexJamendoFollower(id: "9900011", tail: tail, key: farKey)                    // incompatible key
        try await indexJamendoFollower(id: "9900012", tail: tail, bpmScale: 1.5)                  // tempo out of tolerance
        try await indexJamendoFollower(id: "9900013", tail: tail, index: false)                   // incomplete facts (unindexed)
        // A different genre: stored through the lifecycle, never by rewriting a seeded row.
        let tailFacts = try XCTUnwrap(tail.facts), tailTraits = try XCTUnwrap(tail.traits)
        try await store.registerJamendoCatalogTrack(trackID: "9900014")
        try await store.markBlendEligible(
            key: BlendCatalogTrack.jamendoKey(trackID: "9900014"),
            facts: StarterTrackFacts(id: "9900014", durationSeconds: 240, bpm: tailFacts.bpm, beatPeriod: tailFacts.beatPeriod,
                                     beatPhase: 0.2, rmsDB: tailFacts.rmsDB),
            traits: BlendTraits(genre: tailTraits.genre == "Jazz" ? "Metal" : "Jazz", subgenre: nil, camelotKey: tailTraits.camelotKey))
        let player = try await startForKeepPlaying(blend, jamendo: ["9900011": 240, "9900012": 240, "9900013": 240, "9900014": 240])
        let before = player.queue.count
        await player.extendKeepPlayingQueueForTesting()
        let ids = player.starterSession?.trackIDs ?? []
        for rejected in ["9900011", "9900012", "9900013", "9900014"] {
            XCTAssertFalse(ids.contains(rejected), "\(rejected) must not be appended")
        }
        XCTAssertTrue(player.keepPlayingLastExtensionWasFallback, "the no-candidate case is visible")
        XCTAssertEqual(player.keepPlayingFallbackReason, .unavailable)
        XCTAssertTrue(player.starterSession?.sequential == true)
        XCTAssertGreaterThan(player.queue.count, before, "a verified sequential bridge keeps playing")
        for row in player.queue.dropFirst(before) {
            XCTAssertTrue(StarterBlendPack.v1.owns(try XCTUnwrap(URL(string: row.asset?.remoteURL ?? ""))))
        }
    }

    /// The seeded catalog gives every blend its own genre, so no mirrored row is genuinely compatible with another
    /// blend's tail and none is manufactured: the mirrored path is proven at the admission and row-building seams.
    func testMirroredStarterCandidateKeepsItsPinnedReleaseAsset() async throws {
        try await indexSeededCatalog()
        let rows = try await LibraryStore.shared.blendCatalogTracks(atLeast: .blendEligible, packTag: StarterBlendPack.v1.releaseTag)
        let candidate = try XCTUnwrap(rows.first { $0.isKeepPlayingCandidate(in: .v1) })
        let locator = try XCTUnwrap(candidate.keepPlayingLocator(in: .v1))
        XCTAssertEqual(locator, StarterBlendPack.v1.locator(trackID: candidate.trackID))
        let built = try StarterBlendPlayback.rows(blendID: "t", title: "Keep Playing", trackIDs: [candidate.trackID], pack: .v1,
                                                  locators: [candidate.trackID: locator])
        XCTAssertTrue(StarterBlendPack.v1.owns(try XCTUnwrap(URL(string: built.first?.asset?.remoteURL ?? ""))))
        XCTAssertEqual(BlendCatalogTrack.catalogKey(forTrackID: candidate.trackID, pack: .v1), candidate.catalogKey)
    }

    func testKeepPlayingNeverUsesSyntheticOrUnmirroredStarterIDs() async throws {
        let pack = StarterBlendPack.v1
        var row = BlendCatalogTrack(catalogKey: BlendCatalogTrack.key(pack: pack, trackID: "999999999"), packTag: pack.releaseTag,
                                    state: .blendEligible, durationSeconds: 240, bpm: 100, beatPeriod: 0.6, beatPhase: 0.2,
                                    rmsDB: -12, updatedAt: Date(), genre: "Electronic", subgenre: nil, camelotKey: "8A")
        row.sourceKind = .starterRelease
        XCTAssertTrue(row.isSelectable)
        XCTAssertNil(row.keepPlayingLocator(in: pack))
        row.sourceKind = .jamendo; row.providerTrackID = "999999999"
        XCTAssertNil(row.keepPlayingLocator(in: pack), "a Starter-tagged row is never a Jamendo source")
    }

    func testExhaustedPackContinuationAppendsVerifiedSequentialFallbackBeforeEnd() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let player = try await start(blend, factory: SynthCatalog.Factory(blend))
        player.keepPlayingEnabled = true
        await player.extendKeepPlayingQueueForTesting()
        XCTAssertGreaterThan(player.queue.count, blend.trackIDs.count)
        XCTAssertTrue(player.keepPlayingLastExtensionWasFallback)
        XCTAssertEqual(player.keepPlayingFallbackReason, .unavailable)
        let appended = Array(player.queue.dropFirst(blend.trackIDs.count))
        XCTAssertFalse(appended.isEmpty)
        for row in appended {
            let url = try XCTUnwrap(URL(string: row.asset?.remoteURL ?? ""))
            XCTAssertTrue(StarterBlendPack.v1.owns(url), "fallback uses only verified pack audio")
        }
        XCTAssertTrue(player.starterSession?.sequential == true)
        XCTAssertEqual(player.starterSession?.plans.count, blend.edgePlans.count,
                       "there is no invented bridge plan into sequential fallback")
    }

    func testPlayableFallbackNeverClaimsABlendForItsBridge() async throws {
        let blend = StarterBlendCatalog.blends[1]
        let player = try await start(blend, factory: SynthCatalog.Factory(blend))
        player.keepPlayingEnabled = true
        await player.extendKeepPlayingQueueForTesting()
        let bridge = TransitionEdgeKey(from: player.queueOccurrences[blend.trackIDs.count - 1],
                                       to: player.queueOccurrences[blend.trackIDs.count])
        XCTAssertNil(player.transitionExecution.snapshot(for: bridge))
    }

    func testFallbackReusesAVerifiedCardWhenEveryPackTrackIsAlreadyUsed() async throws {
        let blend = StarterBlendCatalog.blends[2]
        let player = try await start(blend, factory: SynthCatalog.Factory(blend))
        player.keepPlayingEnabled = true
        var session = try XCTUnwrap(player.starterSession)
        let others = StarterBlendCatalog.starterTrackIDs.subtracting(session.trackIDs)
        session.append(trackIDs: Array(others), plans: [], rowIDs: [])
        player.starterSession = session
        let before = player.queue.count
        player.appendPlayableContinuationFallback(for: session)
        XCTAssertEqual(player.queue.count, before + blend.trackIDs.count)
        XCTAssertTrue(player.keepPlayingLastExtensionWasFallback)
        XCTAssertEqual(player.keepPlayingFallbackReason, .unavailable)
        XCTAssertTrue(player.starterSession?.sequential == true)
        for row in player.queue.dropFirst(before) {
            XCTAssertTrue(StarterBlendPack.v1.owns(try XCTUnwrap(URL(string: row.asset?.remoteURL ?? ""))))
        }
    }

    func testAnotherQueueEndsTheStarterSession() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let player = try await start(blend, factory: SynthCatalog.Factory(blend))
        XCTAssertNotNil(player.starterStream)
        player.play(tracks: [try StarterBlendPlayback.catalogRows(for: StarterBlendCatalog.blends[1])[0]], startAt: 0)
        // The new queue is itself a plain (non-session) queue.
        XCTAssertNil(player.starterSession)
        XCTAssertNil(player.starterStream)
        player.pause()
    }

    func testReorderedQueueStopsTheBlendAndSaysWhy() async throws {
        let blend = StarterBlendCatalog.blends[0]
        var statuses: [StarterStreamStatus] = []
        AudioPlayer.shared.starterStatusHandler = { statuses.append($0) }
        let player = try await start(blend, factory: SynthCatalog.Factory(blend))
        player.queue.reverse()
        player.starterQueueOrderChanged()
        guard case .sequential(_, let reason, let retryable)? = statuses.last else { return XCTFail("\(statuses)") }
        XCTAssertTrue(reason.contains("queue order changed"))
        XCTAssertFalse(retryable)
        XCTAssertNil(player.starterStream)
        player.pause()
    }

    func testBoundedPrecomputedPlaybackPublishesDurationAndDecreasingRemainingTime() async throws {
        let blend = StarterBlendCatalog.blends[0]
        let player = try await start(blend, factory: SynthCatalog.Factory(blend))
        let expected = try XCTUnwrap(player.queue[0].track.durationSec)
        XCTAssertEqual(player.duration, expected, accuracy: 0.000_001)
        XCTAssertGreaterThan(player.duration, 0)

        player.starterStreamPosition(seconds: 17.25)
        XCTAssertEqual(player.currentTime, 17.25, accuracy: 0.01)
        XCTAssertEqual(player.duration - player.currentTime, expected - 17.25, accuracy: 0.01)

        player.starterStreamDidAdvance(to: 1)
        let secondDuration = try XCTUnwrap(player.queue[1].track.durationSec)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertEqual(player.duration, secondDuration, accuracy: 0.000_001)
        XCTAssertGreaterThan(player.duration, 0)
        player.pause()
    }
}
#endif
