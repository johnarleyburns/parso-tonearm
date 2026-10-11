import XCTest
@testable import TonearmCore

/// How a larger starter behaves on first launch: reading it (embeddings rebuilt from the
/// projection), merging it into the library, and loading the library's rows. Opt-in timing
/// run: TONEARM_STARTER_SCALE=<tracks> swift test -c release -Xswiftc -enable-testing --filter StarterScaleTests
final class StarterScaleTests: XCTestCase {
    func testTimingAtScale() async throws {
        guard let count = ProcessInfo.processInfo.environment["TONEARM_STARTER_SCALE"].flatMap(Int.init) else {
            throw XCTSkip("TONEARM_STARTER_SCALE not set")
        }
        let base = try XCTUnwrap(StarterLibrary.shared, "needs Resources/Starter/starter.sqlite").tracks()
        let tracks = (0..<count).map { i -> BuiltInMoodTrack in
            let t = base[i % base.count]
            return BuiltInMoodTrack(
                id: "jamendo-\(10_000_000 + i)", title: t.title, artist: t.artist + " \(i / base.count)",
                genre: t.genre, license: t.license, licenseURL: t.licenseURL, durationSec: t.durationSec,
                streamURL: t.streamURL + "&copy=\(i)", artworkURL: t.artworkURL, dimensions: t.dimensions,
                scale: t.scale, quantizedVector: t.quantizedVector, bpm: t.bpm, key: t.key, energy: t.energy,
                analysisScopeSeconds: t.analysisScopeSeconds)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let clock = ContinuousClock()
        var t0 = clock.now
        try StarterLibraryWriter.create(at: dir.appendingPathComponent("starter.sqlite"), tracks: tracks,
                                        meta: ["content_version": "scale"], embeddingDimensions: 128)
        let build = clock.now - t0
        let size = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("starter.sqlite").path)[.size] as? Int ?? 0

        t0 = clock.now
        let starter = try StarterLibrary(url: dir.appendingPathComponent("starter.sqlite"))
        let read = try starter.tracks()
        let readTime = clock.now - t0

        let store = try LibraryStore(inMemory: true)
        t0 = clock.now
        _ = try await store.mergeStarterLibrary(read, sourceTitle: "Mood Starter", licenseText: "cc",
                                                versions: StarterMergeVersions(pipeline: 1, model: 1, preprocessing: 1,
                                                                               sampling: 1, musicalAnalysis: 2))
        let merge = clock.now - t0
        t0 = clock.now
        let rows = try await store.allTrackRows()
        let load = clock.now - t0
        let librarySize = try await store.dbQueue.read { db in
            (try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0) * (try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0)
        }
        print("SCALE \(count) tracks: starter \(size / 1_000_000) MB (build \(build)), read+rebuild \(readTime), merge \(merge), allTrackRows \(rows.count) in \(load), library \(librarySize / 1_000_000) MB")
    }
}
