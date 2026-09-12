import AVFoundation
import GRDB
import XCTest

@testable import TonearmCore
@testable import TonearmDJ
@testable import TonearmDiscovery

/// C02 (IMPLEMENT_CLAP_PLAN.md / plan §11's required C02 integration test):
/// proves that an imported core track, `SearchService`'s unified retrieval,
/// and `DeckLoader`'s deck-loading (playback selection) all agree on the
/// SAME core `LibraryStore` writer and the SAME core track ID — with no
/// DJTrackRow/DJ-local ID anywhere in the path. This covers BOTH queue
/// sources: `.allTracks` (the whole library) and `.playlist` (a DJ crate
/// built by `PlaylistCrateImporter`, which since dj_v8 stores core track IDs
/// directly instead of copying into DJ-local `track`/`asset` rows).
final class DeckLoaderCoreIdentityTests: XCTestCase {

    func testImportSearchAndDeckLoadShareOneCoreTrackID() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // 1. "Import": a real core LibraryStore write — the one writer every
        //    consumer below must agree with.
        let coreID = fixture.trackID

        // 2. "Search": the unified retrieval engine (plan §9), an ordinary
        //    scoped library browse (empty query, no filters — no CLAP model
        //    needed), reading the SAME core database.
        let writer = await fixture.library.dbQueue
        let searchService = SearchService(
            writer: writer,
            index: VectorIndex(writer: writer,
                               cacheURL: fixture.directory.appendingPathComponent("vectors.bin")),
            models: ModelManager(resourceProvider: { .unavailable }))
        let response = await searchService.search(DiscoverySearchQuery())
        XCTAssertEqual(response.state, .ready)
        XCTAssertTrue(response.results.contains { $0.trackID == coreID },
                      "search must surface the imported track under its core track ID")

        // 3. "Playback selection": DeckLoader's `.allTracks` browse and its
        //    `load(trackID:)`, re-pointed at the same core LibraryStore this
        //    session (C02) — never a DJTrackRow / separate DJ ID.
        let deckRows = try await fixture.deckLoader.rows(in: .allTracks)
        XCTAssertTrue(deckRows.contains { $0.trackID == coreID },
                      "the deck queue must list the track under its core track ID")

        let outcome = await fixture.deckLoader.load(trackID: coreID)
        guard case .loaded = outcome else {
            return XCTFail("expected the core-identity track to load; got \(outcome)")
        }

        // 4. Direct confirmation: the exact same row LibraryStore itself
        //    reports for this ID.
        let row = try await fixture.library.trackRow(id: coreID)
        XCTAssertEqual(row?.id, coreID)
    }

    /// C02 crate-side coverage: `PlaylistCrateImporter.importCrate` (writing
    /// into `playlist_item` per dj_v8) and `DeckLoader`'s `.playlist` queue
    /// source resolve the SAME core track ID — no DJ-local copy anywhere.
    func testCrateImportAndDeckLoadShareOneCoreTrackID() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coreID = fixture.trackID

        let playlist = try await fixture.library.createManualPlaylist(
            title: "Crate Source", trackIds: [coreID])

        let importer = PlaylistCrateImporter(library: fixture.library, djLibrary: fixture.djLibrary)
        let result = try await importer.importCrate(playlistID: playlist.id!, title: "My Crate")
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.skipped, 0)

        guard case .playlist(let crateID, _) = result.source else {
            return XCTFail("expected a .playlist source from importCrate")
        }

        // No DJ-local track row was created for the crate's member — in
        // fact the DJ-local catalog table no longer exists at all.
        let hasTrackTable = try await fixture.djLibrary.pool.read { db in
            try db.tableExists("track")
        }
        XCTAssertFalse(hasTrackTable)

        let deckRows = try await fixture.deckLoader.rows(in: .playlist(id: crateID, title: "My Crate"))
        XCTAssertEqual(deckRows.map(\.trackID), [coreID],
                       "the crate's deck queue must list the track under its core track ID")

        let outcome = await fixture.deckLoader.load(trackID: coreID)
        guard case .loaded = outcome else {
            return XCTFail("expected the crate's core-identity track to load; got \(outcome)")
        }
    }

    /// The single-chain integration test C02 (sessions 15/16/17) flagged as
    /// still missing: import → real `SearchService` search → crate creation
    /// (`PlaylistCrateImporter`) → deck load, all resolving the SAME core
    /// track id through the SAME core `LibraryStore` writer, with zero
    /// DJ-local `DJTrack` rows anywhere in the chain.
    func testImportSearchCrateCreationAndDeckLoadShareOneCoreTrackID() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let coreID = fixture.trackID

        // 1. "Search": the unified retrieval engine, reading the same core
        //    database the fixture's track was imported into.
        let writer = await fixture.library.dbQueue
        let searchService = SearchService(
            writer: writer,
            index: VectorIndex(writer: writer,
                               cacheURL: fixture.directory.appendingPathComponent("vectors.bin")),
            models: ModelManager(resourceProvider: { .unavailable }))
        let response = await searchService.search(DiscoverySearchQuery())
        XCTAssertEqual(response.state, .ready)
        XCTAssertTrue(response.results.contains { $0.trackID == coreID },
                      "search must surface the imported track under its core track ID")

        // 2. "Crate creation": build a manual playlist over the SAME core id
        //    search just returned, then import it as a DJ crate.
        let playlist = try await fixture.library.createManualPlaylist(
            title: "Search-to-Crate", trackIds: [coreID])
        let importer = PlaylistCrateImporter(library: fixture.library, djLibrary: fixture.djLibrary)
        let result = try await importer.importCrate(playlistID: playlist.id!, title: "Chain Crate")
        XCTAssertEqual(result.imported, 1)
        guard case .playlist(let crateID, _) = result.source else {
            return XCTFail("expected a .playlist source from importCrate")
        }

        // No DJ-local track row was created anywhere in this chain — the
        // DJ-local catalog table no longer exists at all.
        let hasTrackTable = try await fixture.djLibrary.pool.read { db in
            try db.tableExists("track")
        }
        XCTAssertFalse(hasTrackTable)

        // 3. "Deck load": the crate's queue and `load(trackID:)` resolve the
        //    exact id search surfaced.
        let deckRows = try await fixture.deckLoader.rows(in: .playlist(id: crateID, title: "Chain Crate"))
        XCTAssertEqual(deckRows.map(\.trackID), [coreID])
        let outcome = await fixture.deckLoader.load(trackID: coreID)
        guard case .loaded = outcome else {
            return XCTFail("expected the chain's core-identity track to load; got \(outcome)")
        }
    }

    // MARK: - Fixture

    private struct Fixture {
        let directory: URL
        let library: LibraryStore
        let djLibrary: DJLibraryStore
        let deckLoader: DeckLoader
        let trackID: Int64
    }

    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeckLoaderCoreIdentityTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let audioURL = directory.appendingPathComponent("track.wav")
        try Self.writeSineWAV(seconds: 1.0, to: audioURL)

        let library = try LibraryStore(inMemory: true)
        let source = try await library.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Fixture",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let track = try await library.insertTrack(Track(
            id: nil, albumId: nil, sourceId: source.id!, title: "One", trackNo: nil,
            discNo: nil, durationSec: 1, codec: "WAV", sampleRate: 44_100,
            bitDepthOrBitrate: nil, sortKey: "One"))
        _ = try await library.insertAsset(Asset(
            id: nil, trackId: track.id!, kind: .localRef,
            bookmark: BookmarkVault.makeBookmark(for: audioURL), relPath: nil,
            remoteURL: nil, altRemoteURL: nil,
            sizeBytes: nil, unsupportedReason: nil))

        let djStore = try DJLibraryStore(path: directory.appendingPathComponent("dj.sqlite"))
        let deckLoader = DeckLoader(library: library, djLibrary: djStore)

        return Fixture(directory: directory, library: library, djLibrary: djStore,
                       deckLoader: deckLoader, trackID: track.id!)
    }

    private static func writeSineWAV(seconds: Double, to url: URL) throws {
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
        file.close()
    }
}
