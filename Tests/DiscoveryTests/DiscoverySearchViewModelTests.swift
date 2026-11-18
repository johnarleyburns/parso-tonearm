#if !os(watchOS)
import Foundation
import GRDB
import ParsoAudioNeural
import Testing

@testable import TonearmCore
@testable import TonearmDiscovery

/// State-mapping + cadence tests for `DiscoverySearchViewModel` — no SwiftUI
/// rendering (plan §10.1: "the VM must be testable without SwiftUI"). The pure
/// state machine is covered separately in `DiscoverySearchPresentationTests`;
/// this drives the VM against a real `DiscoverySearchCoordinator` +
/// `SearchService` over an in-memory catalog.
@MainActor
@Suite final class DiscoverySearchViewModelTests {
    private let dims = 8
    private var cacheURL: URL!

    init() async throws {
        cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vm-\(UUID().uuidString).bin")
    }

    deinit {
        try? FileManager.default.removeItem(at: cacheURL)
    }

    private func unit(_ v: [Float]) -> [Float] { SemanticPooling.l2Normalized(v) }

    private struct Deps {
        let vm: DiscoverySearchViewModel
        let queue: DatabaseQueue
        let played: Box<[Int64]>
        let analyzed: Box<[Int64]>
        let downloadModelsCalls: Box<Int>
    }

    final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ v: T) { value = v }
    }

    private func makeVM(
        queryVector: [Float]? = nil,
        metadata: @escaping @Sendable (DiscoverySearchQuery) async -> Result<[TrackRow], any Error> = { _ in .success([]) }
    ) async throws -> Deps {
        let queue = try SearchFixture.makeQueue()
        let models = ModelManager(resourceProvider: { .unavailable })
        if let queryVector {
            await models.injectModelForTesting(FixedTextModel(dimensions: dims, vector: queryVector))
        }
        let index = VectorIndex(writer: queue, cacheURL: cacheURL)
        let service = SearchService(writer: queue, index: index, models: models)
        let coordinator = DiscoverySearchCoordinator(service: service, debounce: .milliseconds(5))
        let played = Box<[Int64]>([])
        let analyzed = Box<[Int64]>([])
        let dl = Box<Int>(0)
        let vm = DiscoverySearchViewModel(
            coordinator: coordinator,
            service: service,
            metadataSearch: metadata,
            onPlay: { result in played.value.append(result.trackID) },
            onAnalyzeTrack: { id in analyzed.value.append(id) },
            onDownloadModels: { dl.value += 1 })
        return Deps(vm: vm, queue: queue, played: played, analyzed: analyzed, downloadModelsCalls: dl)
    }

    private func settle(
        _ vm: DiscoverySearchViewModel,
        timeout: TimeInterval = 3,
        until: @escaping (DiscoverySearchViewModel) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if until(vm) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private nonisolated static func trackRow(id: Int64, title: String) -> TrackRow {
        let track = Track(
            id: id, albumId: nil, sourceId: 1, title: title, trackNo: nil, discNo: nil,
            durationSec: 100, codec: "wav", sampleRate: 44_100, bitDepthOrBitrate: nil,
            sortKey: title.lowercased())
        return TrackRow(track: track, album: nil, source: nil, asset: nil)
    }

    // MARK: - Idle

    @Test func testStartsIdleAndTrivialQueryStaysIdle() async throws {
        let d = try await makeVM()
        #expect(d.vm.screen == .idle)
        d.vm.searchText = "   "
        await settle(d.vm) { _ in true }
        #expect(d.vm.screen == .idle)
        #expect(d.vm.results.isEmpty)
    }

    // MARK: - Metadata path

    @Test func testPlayMoodEnqueuesAllCompatibleResultsAndStartsOnceWithoutOpeningBuilder() async throws {
        let rows = [Self.trackRow(id: 1, title: "First"), Self.trackRow(id: 2, title: "Second"), Self.trackRow(id: 3, title: "Incompatible")]
        let d = try await makeVM(metadata: { _ in .success(rows) })
        d.vm.inputMode = .metadata
        d.vm.searchText = "mood"
        await settle(d.vm) { $0.screen.hasResults }
        d.vm.setMatchingTracksOnly(true)
        await settle(d.vm) { $0.screen.hasResults }
        var started: [[Int64]] = []
        let played = d.vm.playMood(metadata: [1: .init(bpm: 100, camelotKey: "8A"),
            2: .init(bpm: 104, camelotKey: "9A"), 3: .init(bpm: 170, camelotKey: "4B")]) {
                started.append($0.map(\.id))
            }
        #expect(played)
        #expect(started == [[1, 2]])
        #expect(d.played.value.isEmpty, "Queue playback must not invoke single-track playback")
        #expect(!d.vm.playMood(metadata: [:], onPlayQueue: { _ in Issue.record("Do not start an incompatible/empty queue") }))
    }

    /// Real report: with "Mix-compatible tracks" off, pressing Play showed "completely different
    /// tracks" than the displayed results. Root cause: `queueTrackIDs`'s BPM/key filtering ran
    /// unconditionally, keyed only on whether `metadata` happened to have an entry for each
    /// track — most tracks lack BPM/key analysis at any given moment (it's a separate, unordered
    /// background stage from the semantic index that produces these search results at all), so
    /// most of the displayed list was silently dropped. `matchingTracksOnly` must gate the
    /// filtering itself: off means Play queues the displayed results, in their own order, full
    /// stop — regardless of which (if any) have BPM/key metadata.
    @Test func testPlayMoodWithoutMatchingTracksOnlyPlaysEveryResultInDisplayOrder() async throws {
        let rows = [Self.trackRow(id: 1, title: "First"), Self.trackRow(id: 2, title: "Second"), Self.trackRow(id: 3, title: "Third")]
        let d = try await makeVM(metadata: { _ in .success(rows) })
        d.vm.inputMode = .metadata
        d.vm.searchText = "mood"
        await settle(d.vm) { $0.screen.hasResults }
        #expect(!d.vm.matchingTracksOnly, "default must be off")
        var started: [[Int64]] = []
        // No track here has BPM/key metadata — under the old, always-filtering behavior this
        // would drop every result and refuse to play at all.
        let played = d.vm.playMood(metadata: [:]) { started.append($0.map(\.id)) }
        #expect(played)
        #expect(started == [[1, 2, 3]], "must queue the full displayed list, in order, unfiltered")
    }

    @Test func testDisplayResultsMatchQueuedOrderWithAndWithoutMatchingTracksOnly() async throws {
        let rows = [Self.trackRow(id: 1, title: "First"), Self.trackRow(id: 2, title: "Second"), Self.trackRow(id: 3, title: "Incompatible")]
        let d = try await makeVM(metadata: { _ in .success(rows) })
        d.vm.inputMode = .metadata
        d.vm.searchText = "mood"
        await settle(d.vm) { $0.screen.hasResults }
        let meta: [Int64: DJLoadTrackInfo] = [1: .init(bpm: 100, camelotKey: "8A"),
            2: .init(bpm: 104, camelotKey: "9A"), 3: .init(bpm: 170, camelotKey: "4B")]
        for enabled in [false, true] {
            d.vm.setMatchingTracksOnly(enabled)
            await settle(d.vm) { $0.screen.hasResults }
            var started: [Int64] = []
            #expect(d.vm.playMood(metadata: meta) { started = $0.map(\.id) })
            #expect(d.vm.displayResults(metadata: meta).map(\.trackID) == started)
        }
    }

    @Test func testMetadataTextSearchProducesBrowseResults() async throws {
        let rows = [Self.trackRow(id: 1, title: "Blue"), Self.trackRow(id: 2, title: "Bluer")]
        let d = try await makeVM(metadata: { q in
            q.text.lowercased().contains("blue") ? .success(rows) : .success([])
        })
        d.vm.inputMode = .metadata
        d.vm.searchText = "blue"
        await settle(d.vm) { $0.screen.hasResults }
        #expect(d.vm.screen == .results(kind: .metadataBrowse, count: 2, stillIndexing: false))
        #expect(d.vm.results.map(\.trackID) == [1, 2])
        #expect(d.vm.results.first?.similarity == nil, "metadata rows carry no fabricated score")
    }

    @Test func testMetadataSearchNoHitsIsNoMatches() async throws {
        let d = try await makeVM(metadata: { _ in .success([]) })
        d.vm.inputMode = .metadata
        d.vm.searchText = "zzz"
        await settle(d.vm) { if case .noMatches = $0.screen { return true } else { return false } }
        #expect(d.vm.screen == .noMatches(kind: .metadataBrowse))
    }

    @Test func testMetadataSearchFailurePropagatesSearchFailed() async throws {
        struct E: Error {}
        let d = try await makeVM(metadata: { _ in .failure(E()) })
        d.vm.inputMode = .metadata
        d.vm.searchText = "x"
        await settle(d.vm) { $0.screen == .searchFailed }
        #expect(d.vm.screen == .searchFailed)
    }

    // MARK: - Validation

    @Test func testReversedBPMRangeSurfacesValidationIssue() async throws {
        let d = try await makeVM(metadata: { _ in .success([]) })
        d.vm.inputMode = .metadata
        d.vm.searchText = "x"
        d.vm.bpmMinText = "140"
        d.vm.bpmMaxText = "120"
        await settle(d.vm) { if case .validationError = $0.screen { return true } else { return false } }
        guard case .validationError(let issues) = d.vm.screen else {
            Issue.record("expected validationError")
            return
        }
        #expect(issues.contains(.bpmReversed(min: 140, max: 120)))
    }

    @Test func testUnparseableBPMSurfacesNotFinite() async throws {
        let d = try await makeVM()
        d.vm.inputMode = .findBySound
        d.vm.searchText = "x"
        d.vm.bpmMinText = "abc"
        await settle(d.vm) { if case .validationError = $0.screen { return true } else { return false } }
        guard case .validationError(let issues) = d.vm.screen else {
            Issue.record("expected validationError")
            return
        }
        #expect(issues.contains(.bpmNotFinite))
    }

    // MARK: - Find by sound

    @Test func testFindBySoundReturnsSemanticResults() async throws {
        let q = unit([1, 0, 0, 0, 0, 0, 0, 0])
        let d = try await makeVM(queryVector: q)
        try await d.queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "match")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [1, 0, 0, 0, 0, 0, 0, 0])
        }
        d.vm.inputMode = .findBySound
        d.vm.searchText = "bright synth"
        await settle(d.vm) { $0.screen.hasResults }
        #expect(d.vm.screen == .results(kind: .semantic, count: 1, stillIndexing: false))
        #expect(d.vm.results.first?.trackID == 1)
        #expect(d.vm.results.first?.similarity != nil)
    }

    @Test func testFindBySoundWithoutTextModelIsModelMissing() async throws {
        let d = try await makeVM(queryVector: nil)  // no text encoder injected
        try await d.queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "x")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [1, 0, 0, 0, 0, 0, 0, 0])
        }
        d.vm.inputMode = .findBySound
        d.vm.searchText = "anything"
        await settle(d.vm) { $0.screen == .modelMissing }
        #expect(d.vm.screen == .modelMissing)
        d.vm.downloadModels()
        #expect(d.downloadModelsCalls.value == 1)
    }

    // MARK: - Filter-only (no model needed)

    @Test func testFilterOnlyModeNeedsNoModel() async throws {
        let d = try await makeVM(queryVector: nil)
        try await d.queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let t1 = try SearchFixture.seedTrack(db, sourceId: s, title: "fast")
            let a1 = try SearchFixture.seedAsset(db, trackId: t1)
            try SearchFixture.seedAnalysis(db, trackId: t1, assetId: a1, bpm: 128)
            let t2 = try SearchFixture.seedTrack(db, sourceId: s, title: "slow")
            let a2 = try SearchFixture.seedAsset(db, trackId: t2)
            try SearchFixture.seedAnalysis(db, trackId: t2, assetId: a2, bpm: 90)
        }
        d.vm.inputMode = .metadata
        d.vm.bpmMinText = "125"
        d.vm.bpmMaxText = "132"
        await settle(d.vm) { $0.screen.hasResults }
        #expect(d.vm.screen == .results(kind: .filterOnly, count: 1, stillIndexing: false))
        #expect(d.vm.results.first?.trackID == 1)
    }

    // MARK: - Similar / "More like this"

    @Test func testMoreLikeThisWithUnindexedReferenceOffersAnalyze() async throws {
        let d = try await makeVM()
        try await d.queue.write { db in
            let s = try SearchFixture.seedSource(db)
            _ = try SearchFixture.seedTrack(db, sourceId: s, title: "ref")
        }
        d.vm.moreLikeThis(trackID: 1)
        await settle(d.vm) { if case .analyzeReference = $0.screen { return true } else { return false } }
        #expect(d.vm.screen == .analyzeReference(trackID: 1))
        #expect(d.vm.referenceTrackID == 1)
        d.vm.analyzeReference()
        #expect(d.analyzed.value == [1])
        d.vm.exitSimilarMode()
        #expect(d.vm.referenceTrackID == nil)
    }

    @Test func testMoreLikeThisExcludesReferenceFromResults() async throws {
        let d = try await makeVM()
        try await d.queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let ref = try SearchFixture.seedTrack(db, sourceId: s, title: "ref")
            let ra = try SearchFixture.seedAsset(db, trackId: ref)
            try SearchFixture.seedEmbedding(db, trackId: ref, assetId: ra, vector: [1, 0, 0, 0, 0, 0, 0, 0])
            let other = try SearchFixture.seedTrack(db, sourceId: s, title: "other")
            let oa = try SearchFixture.seedAsset(db, trackId: other)
            try SearchFixture.seedEmbedding(db, trackId: other, assetId: oa, vector: [0.9, 0.1, 0, 0, 0, 0, 0, 0])
        }
        d.vm.moreLikeThis(trackID: 1)
        await settle(d.vm) { $0.screen.hasResults }
        #expect(d.vm.results.map(\.trackID) == [2], "reference is absent from its own results")
        #expect(d.vm.matchingReferenceTrackID == 1)
        #expect(!d.vm.matchingTracksOnly, "matching is opt-in in Find Music")

        d.vm.setMatchingTracksOnly(true)
        await settle(d.vm) { $0.screen == .matchingReferenceUnavailable }
        #expect(d.vm.screen == .matchingReferenceUnavailable)
    }

    // MARK: - Refinement chips

    @Test func testRefinementChipsAddDedupeAndRemove() async throws {
        let d = try await makeVM(queryVector: unit([1, 0, 0, 0, 0, 0, 0, 0]))
        try await d.queue.write { db in
            let s = try SearchFixture.seedSource(db)
            let t = try SearchFixture.seedTrack(db, sourceId: s, title: "x")
            let a = try SearchFixture.seedAsset(db, trackId: t)
            try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: [1, 0, 0, 0, 0, 0, 0, 0])
        }
        d.vm.inputMode = .findBySound
        d.vm.searchText = "warm pads"
        await settle(d.vm) { $0.screen.hasResults }

        d.vm.addMoreLike("brighter")
        d.vm.addMoreLike("brighter")  // dedupe
        d.vm.addLessLike("vocals")
        #expect(d.vm.positiveRefinements == ["brighter"])
        #expect(d.vm.negativeRefinements == ["vocals"])
        await settle(d.vm) { $0.screen.hasResults }

        d.vm.removeMoreLike("brighter")
        #expect(d.vm.positiveRefinements == [])
        d.vm.clearRefinements()
        #expect(d.vm.negativeRefinements == [])
    }

    // MARK: - Cadence / supersession

    @Test func testSupersededMetadataQueryDoesNotOverwriteNewerResult() async throws {
        let slow = [Self.trackRow(id: 10, title: "slow")]
        let fast = [Self.trackRow(id: 20, title: "fast")]
        let d = try await makeVM(metadata: { q in
            if q.text == "slow" {
                try? await Task.sleep(for: .milliseconds(400))
                return .success(slow)
            }
            return .success(fast)
        })
        d.vm.inputMode = .metadata
        d.vm.searchText = "slow"
        try await Task.sleep(for: .milliseconds(30))
        d.vm.searchText = "fast"
        await settle(d.vm) { $0.results.map(\.trackID) == [20] }
        // Give the slow task time to (not) land.
        try await Task.sleep(for: .milliseconds(500))
        #expect(d.vm.results.map(\.trackID) == [20], "the superseded slow query updated nothing")
        #expect(d.vm.screen == .results(kind: .metadataBrowse, count: 1, stillIndexing: false))
    }

    // MARK: - Play

    @Test func testPlayRoutesThroughInjectedCallback() async throws {
        let d = try await makeVM(metadata: { _ in .success([Self.trackRow(id: 7, title: "p")]) })
        d.vm.inputMode = .metadata
        d.vm.searchText = "p"
        await settle(d.vm) { $0.screen.hasResults }
        d.vm.play(d.vm.results[0])
        #expect(d.played.value == [7])
    }

    // MARK: - Empty scope stays distinct from empty library

    @Test func testExplicitlyEmptyScopeIsEmptyScopeNotIdle() async throws {
        let d = try await makeVM()
        try await d.queue.write { db in
            let s = try SearchFixture.seedSource(db)
            _ = try SearchFixture.seedTrack(db, sourceId: s, title: "x")
        }
        d.vm.inputMode = .findBySound
        d.vm.scope = .sources([])
        await settle(d.vm) { $0.screen == .emptyScope }
        #expect(d.vm.screen == .emptyScope)
    }
}
#endif
