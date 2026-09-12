#if !os(watchOS)
import AVFoundation
import Foundation
import GRDB
import ParsoAudioNeural
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// Plan §9 integration exercise (and the down payment on C02's required
/// "import / playback / search / playlist share one writer and one ID space"
/// test). Drives the FULL real path against ONE core `LibraryStore` writer and
/// core track IDs:
///
///   real `LibraryStore.insertSource/insertTrack/insertAsset`
///     → v19 outbox trigger
///     → `DiscoveryReconciler.processOutbox`
///     → `IndexScheduler` + real `BoundedIndexWorker` (deterministic fake encoder)
///     → `SearchService` query returns the indexed track
///     → "play": the result carries the SAME core track id the library row has
///     → save the `DiscoverySearchQuery` (Codable) → re-run → same result.
///
/// Structured with reusable helpers so C02 can extend it with the DJ playlist /
/// deck load paths once the DJ database is unified onto this writer.
final class DiscoverySearchIntegrationTests: XCTestCase {

    // MARK: - Reusable rig (C02 will extend this)

    final class Ref<T>: @unchecked Sendable {
        var value: T
        init(_ v: T) { value = v }
    }

    struct ImportedTrack {
        let sourceID: Int64
        let trackID: Int64
        let fileURL: URL
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("clap-int-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func spec() -> EmbeddingModelSpec {
        let meta = EmbeddingModelSpec.musicCLAPMetadata
        let bins = meta.fftSize / 2 + 1
        return EmbeddingModelSpec.musicCLAP(
            melFilterBank: [Float](repeating: 0.01, count: bins * meta.melBins))
    }

    private func nominal() -> DiscoverySchedulingSnapshot {
        DiscoverySchedulingSnapshot(
            appState: .foreground, thermalState: .nominal, batteryLevel: 0.9, isCharging: true,
            isLowPowerModeEnabled: false, isPlaybackActive: false, isUserPaused: false,
            chargingOnlySetting: false, hasBackgroundProcessingGrant: false, hasMemoryWarning: false,
            continuousNominalSeconds: 120)
    }

    private func writeSineWAV(seconds: Double, to url: URL) throws {
        let sr = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        var remaining = Int((seconds * sr).rounded())
        var phase = 0.0
        let inc = 2.0 * Double.pi * 220.0 / sr
        while remaining > 0 {
            let n = min(Int(sr), remaining)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            let ch = buf.floatChannelData![0]
            for i in 0..<n { ch[i] = Float(sin(phase) * 0.25); phase += inc }
            try file.write(from: buf)
            remaining -= n
        }
    }

    /// Import ONE track through the real core `LibraryStore` writers only.
    private func importTrack(
        into store: LibraryStore, title: String, sortKey: String, seconds: Double
    ) async throws -> ImportedTrack {
        var source = Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Local Files",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false, licenseText: nil,
            memberCapHit: false)
        source = try await store.insertSource(source)

        let wav = scratch.appendingPathComponent("\(sortKey).wav")
        try writeSineWAV(seconds: seconds, to: wav)

        var track = Track(
            id: nil, albumId: nil, sourceId: source.id!, title: title, trackNo: 1, discNo: nil,
            durationSec: seconds, codec: "wav", sampleRate: 44_100, bitDepthOrBitrate: nil,
            sortKey: sortKey)
        track = try await store.insertTrack(track)

        let asset = Asset(
            id: nil, trackId: track.id!, kind: .localRef, bookmark: nil, relPath: nil,
            remoteURL: wav.absoluteString, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
        try await store.insertAsset(asset)

        return ImportedTrack(sourceID: source.id!, trackID: track.id!, fileURL: wav)
    }

    private func makeAssembly(_ writer: any DatabaseWriter) async -> DiscoveryAssembly {
        let snap = nominal()
        let assembly = DiscoveryAssembly(writer: writer, snapshotProvider: { snap })
        await assembly.models.injectModelForTesting(DeterministicFakeSemanticModel(spec: spec()))
        return assembly
    }

    // MARK: - The exercise

    func testImportToIndexToSearchToPlayToSavedQueryRerunSharesOneWriterAndOneIDSpace() async throws {
        let store = try LibraryStore(inMemory: true)
        let imported = try await importTrack(
            into: store, title: "Warm Analog Pads", sortKey: "0001", seconds: 14)
        let writer = await store.dbQueue

        // --- outbox trigger fired on the real inserts ---
        let outboxRows = try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM discovery_change")!
        }
        XCTAssertGreaterThanOrEqual(outboxRows, 1, "real inserts must have written outbox rows")

        // --- reconcile + schedule + real bounded worker ---
        let assembly = await makeAssembly(writer)
        _ = try await assembly.recoverAndReconcileAtLaunch()
        let completed = try await assembly.drainQueue()
        XCTAssertEqual(completed, 1, "the one imported track indexed to completion")

        let (embeddingTrackID, embeddingDims) = try await writer.read { db -> (Int64?, Int?) in
            let row = try Row.fetchOne(
                db, sql: "SELECT trackId, dimensions FROM discovery_embedding")
            return (row?["trackId"], row?["dimensions"])
        }
        XCTAssertEqual(
            embeddingTrackID, imported.trackID,
            "the embedding references the SAME core track id — one ID space")
        XCTAssertEqual(embeddingDims, spec().dimensions)

        let coverage = try await assembly.jobs.coverage(pipelineVersion: DiscoveryPipelineVersion.pipeline)
        XCTAssertEqual(coverage.complete, 1)

        // --- search returns the indexed track ---
        let query = DiscoverySearchQuery(text: "warm analog pads")
        let response = await assembly.search.search(query)
        XCTAssertEqual(response.state, .ready)
        XCTAssertEqual(response.results.map(\.trackID), [imported.trackID])

        // --- "play": the search result carries the SAME core id a library row has ---
        let libraryRows = try await store.tracks(forSource: imported.sourceID)
        let libraryRow = libraryRows.first { $0.id == imported.trackID }
        XCTAssertNotNil(libraryRow, "the same track is reachable as an ordinary library row")
        XCTAssertEqual(response.results.first?.track.id, libraryRow?.id)
        XCTAssertEqual(response.results.first?.track.track.sourceId, imported.sourceID)

        // --- save the query (Codable) and re-run: identical result ---
        let encoded = try JSONEncoder().encode(query)
        let restored = try JSONDecoder().decode(DiscoverySearchQuery.self, from: encoded)
        XCTAssertEqual(restored, query)
        let rerun = await assembly.search.search(restored)
        XCTAssertEqual(rerun.state, .ready)
        XCTAssertEqual(
            rerun.results.map(\.trackID), response.results.map(\.trackID),
            "the saved query re-runs to the same result")

        // --- the shared saved-search / auto-playlist primitive agrees ---
        let candidates = await assembly.search.candidateTrackIDs(restored)
        XCTAssertEqual(candidates, [imported.trackID])
    }

    func testViewModelFindBySoundPathSurfacesImportedTrackAndPlayCarriesCoreID() async throws {
        let store = try LibraryStore(inMemory: true)
        let imported = try await importTrack(
            into: store, title: "Bright Danceable Synths", sortKey: "0001", seconds: 12)
        let writer = await store.dbQueue
        let assembly = await makeAssembly(writer)
        _ = try await assembly.recoverAndReconcileAtLaunch()
        _ = try await assembly.drainQueue()

        let service = await assembly.search
        let coordinator = DiscoverySearchCoordinator(service: service, debounce: .milliseconds(5))
        let played = Ref<[Int64]>([])

        let vm = await DiscoverySearchViewModel(
            coordinator: coordinator, service: service,
            metadataSearch: { _ in .success([]) },
            onPlay: { played.value.append($0.trackID) })

        await MainActor.run {
            vm.inputMode = .findBySound
            vm.searchText = "bright danceable synths"
        }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let done = await MainActor.run { vm.screen.hasResults }
            if done { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let ids = await MainActor.run { vm.results.map(\.trackID) }
        XCTAssertEqual(ids, [imported.trackID])

        await MainActor.run {
            if let first = vm.results.first { vm.play(first) }
        }
        XCTAssertEqual(played.value, [imported.trackID], "play routes the core track id back")

        // Save + re-run through the VM's Codable brief.
        let brief = await MainActor.run { vm.currentQuery() }
        let restored = try JSONDecoder().decode(
            DiscoverySearchQuery.self, from: try JSONEncoder().encode(brief))
        let rerun = await service.search(restored)
        XCTAssertEqual(rerun.results.map(\.trackID), [imported.trackID])
    }

    func testSavedFilterOnlyQueryRerunsWithoutAModel() async throws {
        let store = try LibraryStore(inMemory: true)
        let imported = try await importTrack(
            into: store, title: "Slow Atmospheric", sortKey: "0001", seconds: 12)
        let writer = await store.dbQueue
        let assembly = await makeAssembly(writer)
        _ = try await assembly.recoverAndReconcileAtLaunch()
        _ = try await assembly.drainQueue()

        // The bounded worker's musical-analysis stage populated a real BPM for
        // this track; scope it with a wide BPM gate so filter-only matches it.
        let bpm = try await writer.read { db in
            try Double.fetchOne(db, sql: "SELECT bpm FROM discovery_track_analysis WHERE trackId = ?",
                arguments: [imported.trackID])
        }
        try XCTSkipIf(bpm == nil, "musical-analysis stage produced no BPM for the sine fixture")

        var query = DiscoverySearchQuery()
        query.bpmMin = max(1, bpm! - 20)
        query.bpmMax = bpm! + 20
        let encoded = try JSONEncoder().encode(query)
        let restored = try JSONDecoder().decode(DiscoverySearchQuery.self, from: encoded)

        // A ModelManager with NO injected model — filter-only must not need one.
        let bareModels = ModelManager(resourceProvider: { .unavailable })
        let bareService = SearchService(
            writer: writer, index: VectorIndex(writer: writer), models: bareModels)
        let response = await bareService.search(restored)
        XCTAssertEqual(response.mode, .filterOnly)
        XCTAssertEqual(response.state, .ready)
        XCTAssertTrue(response.results.map(\.trackID).contains(imported.trackID))
    }
}
#endif
