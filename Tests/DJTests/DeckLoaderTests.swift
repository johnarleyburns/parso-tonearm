import XCTest
import GRDB
@testable import TonearmDJ

/// Plan 5.1 — `DeckLoader`, the library → deck seam (decision 16). Real temp
/// pool + a real WAV file: the FR-LIB-8 gate refuses an incomplete asset, a
/// decode failure is an honest state not a crash, the decode produces a
/// `DeckSource` the engine can actually arm, and the per-deck queue listing
/// reads real library rows.
@MainActor
final class DeckLoaderTests: XCTestCase {

    private func makeStore() throws -> (DJLibraryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeckLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        return (DJLibraryStore(pool: pool), dir)
    }

    private func makeFolder(named name: String, in dir: URL) throws -> URL {
        let folder = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A tiny 16-bit mono PCM WAV (the `DJLibraryStoreTests` shape) that
    /// AVFoundation can actually decode — `seed` makes payloads distinct.
    private func makeWAV(named name: String, in dir: URL, seconds: Double = 0.5,
                         seed: UInt8 = 1) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let sampleRate: UInt32 = 8000
        let dataBytes = UInt32(seconds * 8000) * 2
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(36 + dataBytes), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * 2, to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendLittleEndian(dataBytes, to: &data)
        data.append(contentsOf: Data(repeating: seed, count: Int(dataBytes)))
        try data.write(to: url)
        return url
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    /// Imports a single WAV and returns the first imported track's id.
    private func importOneWAV(store: DJLibraryStore, in dir: URL,
                              seconds: Double = 0.5) async throws -> Int64 {
        let folder = try makeFolder(named: "Music", in: dir)
        _ = try makeWAV(named: "alpha.wav", in: folder, seconds: seconds, seed: 7)
        let summary = try await store.importFolder(folder)
        XCTAssertEqual(summary.added, 1)
        let rows = try await store.tracks(matching: LibraryQuery())
        return try XCTUnwrap(rows.first?.id)
    }

    // MARK: - Queues (§41.9c)

    func testAvailableQueuesListsTheLibraryAndSavedPlaylists() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await importOneWAV(store: store, in: dir)

        let loader = DeckLoader(store: store)
        let queues = try await loader.availableQueues()
        XCTAssertEqual(queues, [.allTracks], "the whole library is always a selectable queue (§41.9c)")

        let playlistID = try await store.pool.write { db in
            var playlist = DJPlaylist(syncID: UUID().uuidString, title: "Set A",
                                      kind: "manual", createdAt: .init(), updatedAt: .init())
            try playlist.insert(db)
            return playlist.id!
        }
        let queuesAfter = try await loader.availableQueues()
        XCTAssertTrue(queuesAfter.contains(.allTracks))
        XCTAssertTrue(queuesAfter.contains(.playlist(id: playlistID, title: "Set A")))
    }

    func testRowsInAllTracksCarryReadinessForEachTrack() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trackID = try await importOneWAV(store: store, in: dir)

        let loader = DeckLoader(store: store)
        let rows = try await loader.rows(in: .allTracks)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.trackID, trackID)
        XCTAssertEqual(rows.first?.title, "alpha")
        XCTAssertEqual(rows.first?.readiness, .ready, "a reachable local file is deck-ready (FR-LIB-8)")
    }

    func testRowsInPlaylistPreserveItsStoredOrder() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(named: "Music", in: dir)
        _ = try makeWAV(named: "alpha.wav", in: folder, seed: 1)
        _ = try makeWAV(named: "beta.wav", in: folder, seed: 2)
        let summary = try await store.importFolder(folder)
        XCTAssertEqual(summary.added, 2)
        let rows = try await store.tracks(matching: LibraryQuery())
        let ids = rows.sorted { $0.title < $1.title }.map(\.id)

        let playlistID = try await store.pool.write { db in
            var playlist = DJPlaylist(syncID: UUID().uuidString, title: "Set A",
                                      kind: "manual", createdAt: .init(), updatedAt: .init())
            try playlist.insert(db)
            let id = playlist.id!
            for (position, trackID) in [ids[1], ids[0]].enumerated() {
                var item = DJPlaylistItem(playlistID: id, trackID: trackID, position: position)
                try item.insert(db)
            }
            return id
        }

        let loader = DeckLoader(store: store)
        let queueRows = try await loader.rows(in: .playlist(id: playlistID, title: "Set A"))
        XCTAssertEqual(queueRows.map(\.trackID), [ids[1], ids[0]],
                       "a deck's queue is the playlist's stored order (§41.9c)")
    }

    // MARK: - The FR-LIB-8 gate

    func testGateRefusesAnIncompleteAsset() async throws {
        let (store, dir) = try makeStore()
        let folder = try makeFolder(named: "Music", in: dir)
        let url = try makeWAV(named: "alpha.wav", in: folder, seed: 9)
        _ = try await store.importFolder(folder)
        let rows = try await store.tracks(matching: LibraryQuery())
        let trackID = try XCTUnwrap(rows.first?.id)

        // The audio vanishes after import (e.g. an ejected drive / a deleted
        // file) — the gate must refuse it rather than present it as deck-ready.
        try FileManager.default.removeItem(at: url)

        let loader = DeckLoader(store: store)
        let outcome = await loader.load(trackID: trackID)
        guard case .refused(let readiness) = outcome else {
            return XCTFail("an incomplete asset must be refused, got \(outcome)")
        }
        XCTAssertFalse(readiness.isReady)
        if case .unavailable(let reason) = readiness {
            XCTAssertFalse(reason.isEmpty, "the refusal carries a user-facing reason")
        } else {
            XCTFail("a refused load reports the unavailable reason")
        }

        let listed = try await loader.rows(in: .allTracks)
        XCTAssertFalse(listed.first?.readiness.isReady ?? true,
                       "a missing-file track is visibly not deck-ready in the queue rows")
    }

    // MARK: - Decode

    @MainActor
    func testLoadDecodesToAUsableDeckSource() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trackID = try await importOneWAV(store: store, in: dir, seconds: 0.5)

        let loader = DeckLoader(store: store)
        let outcome = await loader.load(trackID: trackID)
        guard case .loaded(let box) = outcome else {
            return XCTFail("a reachable local track must load, got \(outcome)")
        }
        XCTAssertEqual(box.source.sampleRate, AudioDecoder.workingSampleRate)
        XCTAssertEqual(box.source.channelCount, 1)
        XCTAssertEqual(box.source.frameCount, Int64(0.5 * 48_000),
                       "the 0.5 s 8 kHz WAV resamples to 48 kHz in the deck's sample space")
        XCTAssertEqual(box.source.grid.bpm, 120, "an unanalysed track gets the honest 120 BPM default grid")

        // The §12.2 ownership transfer end-to-end: the box keeps the PCM alive
        // while the engine renders it.
        let engine = try PerformanceEngine(configuration: .init(sampleRate: 48_000, channelCount: 1,
                                                                ringCapacity: 16))
        try engine.start()
        engine.load(.a, source: box.source)
        engine.play(.a)
        let rendered = try engine.renderMono(1024)
        XCTAssertEqual(rendered.count, 1024)
        XCTAssertTrue(rendered.contains { abs($0) > 0.0001 }, "the decoded track actually renders audio")
    }

    func testDecodeFailureIsAnHonestStateNotACrash() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(named: "Music", in: dir)
        let garbage = folder.appendingPathComponent("broken.wav")
        try Data("this is not a wav file".utf8).write(to: garbage)
        _ = try await store.importFolder(folder)

        let rows = try await store.tracks(matching: LibraryQuery())
        let trackID = try XCTUnwrap(rows.first?.id)

        let loader = DeckLoader(store: store)
        let outcome = await loader.load(trackID: trackID)
        guard case .failed(let failure) = outcome else {
            return XCTFail("an undecodable file must fail honestly, got \(outcome)")
        }
        XCTAssertFalse(failure.message.isEmpty)
    }

    func testLoadedGridUsesTheDetectedGridAtTheDecodeRate() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let trackID = try await importOneWAV(store: store, in: dir)
        try await store.pool.write { db in
            try db.execute(sql: """
                INSERT INTO beat_grid (trackID, syncID, bpm, firstBeatSample, beatCount,
                                       isConstantTempo, source, confidence, version, updatedAt)
                VALUES (?, ?, ?, ?, 4, 1, 'detected', 0.9, 1, ?)
                """, arguments: [trackID, UUID().uuidString, 126.0, 48_000, Date()])
        }

        let loader = DeckLoader(store: store)
        let outcome = await loader.load(trackID: trackID)
        guard case .loaded(let box) = outcome else {
            return XCTFail("expected a load, got \(outcome)")
        }
        XCTAssertEqual(box.source.grid.bpm, 126.0, accuracy: 1e-9)
        XCTAssertEqual(box.source.grid.referenceSample, 48_000, accuracy: 1e-9,
                       "the grid's reference is the detected first beat in the deck's 48 kHz space")
        XCTAssertEqual(box.source.grid.sampleRate, 48_000, accuracy: 1e-9)
    }

    @MainActor
    func testOwnershipTransferAllowsSequentialLoads() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(named: "Music", in: dir)
        _ = try makeWAV(named: "alpha.wav", in: folder, seed: 1)
        _ = try makeWAV(named: "beta.wav", in: folder, seed: 2)
        _ = try await store.importFolder(folder)
        let rows = try await store.tracks(matching: LibraryQuery())
        let ids = rows.sorted { $0.title < $1.title }.map(\.id)

        let loader = DeckLoader(store: store)
        let engine = try PerformanceEngine(configuration: .init(sampleRate: 48_000, channelCount: 1,
                                                                ringCapacity: 16))
        try engine.start()

        // Loading a second track releases the first box (the model replaces its
        // per-deck box on reload) — the deck keeps rendering without a crash.
        var boxes: [DeckSourceBox] = []
        for trackID in ids {
            guard case .loaded(let box) = await loader.load(trackID: trackID) else {
                return XCTFail("every reachable track must load")
            }
            engine.load(.a, source: box.source)
            boxes = [box] // the previous box is dropped — ownership released
            engine.play(.a)
            let rendered = try engine.renderMono(512)
            XCTAssertEqual(rendered.count, 512)
        }
        XCTAssertEqual(boxes.count, 1, "only the newest box is retained after sequential loads")
    }
}
