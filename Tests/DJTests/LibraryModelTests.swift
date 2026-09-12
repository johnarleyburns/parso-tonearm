import AVFoundation
import GRDB
import XCTest
import TonearmCore

@testable import TonearmDJ

/// C02 (IMPLEMENT_CLAP_PLAN.md) Slice B: `LibraryModel` is re-pointed at the
/// core `LibraryStore` with a pull-based refresh (core has no live-
/// observation API) instead of the DJ-local `DJTrackRepository.
/// observeTracks(LibraryQuery())` stream. This proves `refresh()` pulls a
/// real core-imported track and `importFolder` writes through the same core
/// import path the non-DJ Library screen uses (`IngestService.addFolder`),
/// not `DJLibraryStore.importFolder`.
final class LibraryModelTests: XCTestCase {

    @MainActor
    func testRefreshPullsCoreImportedTracks() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let library = try LibraryStore(inMemory: true)
        let source = try await library.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Fixture",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let track = try await library.insertTrack(Track(
            id: nil, albumId: nil, sourceId: source.id!, title: "Core Track", trackNo: nil,
            discNo: nil, durationSec: 180, codec: "WAV", sampleRate: 44_100,
            bitDepthOrBitrate: nil, sortKey: "Core Track"))

        let djStore = try DJLibraryStore(path: dir.appendingPathComponent("dj.sqlite"))
        let model = LibraryModel(library: library, store: djStore)

        XCTAssertTrue(model.rows.isEmpty, "no pull has happened yet")
        await model.refresh()
        XCTAssertEqual(model.rows.map(\.id), [track.id!],
                       "refresh() must pull the core-imported track, not a DJ-local row")
        XCTAssertEqual(model.rows.first?.title, "Core Track")
    }

    @MainActor
    func testImportFolderWritesThroughTheCoreImportPath() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let musicDir = dir.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        try Self.writeSineWAV(seconds: 0.2, to: musicDir.appendingPathComponent("song.wav"))

        let library = try LibraryStore(inMemory: true)
        let djStore = try DJLibraryStore(path: dir.appendingPathComponent("dj.sqlite"))
        let model = LibraryModel(library: library, store: djStore)

        await model.importFolder(musicDir)

        XCTAssertNil(model.importError)
        XCTAssertEqual(model.lastImport?.added, 1)
        XCTAssertEqual(model.rows.count, 1, "the imported track must appear via the core library pull")

        // No DJ-local catalog exists to have received a copy: the import went
        // straight through the core LibraryStore, never a DJ-local
        // `DJLibraryStore.importFolder` — which C02 deleted along with the
        // `track`/`artist`/`album`/`asset` tables it used to write (dj_v12).
        let hasCatalogTrackTable = try await djStore.pool.read { db in try db.tableExists("track") }
        XCTAssertFalse(hasCatalogTrackTable, "the DJ-local catalog table must no longer exist")
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
