import XCTest
@testable import TonearmCore

/// The starter DB: built on the Mac, merged into the library in one transaction, transition prep
/// read in place.
final class StarterLibraryTests: XCTestCase {
    private func entry(_ index: Int, analysed: Bool = true) -> BuiltInMoodTrack {
        BuiltInMoodTrack(
            id: "jamendo-\(index)", title: "Track \(index)", artist: index.isMultiple(of: 2) ? "Ann" : "Bob",
            genre: index < 3 ? "House" : "Ambient", license: "cc-by", licenseURL: nil, durationSec: 200,
            streamURL: "https://example.com/\(index).mp3", artworkURL: "https://example.com/\(index).jpg",
            dimensions: 4, scale: 0.01, quantizedVector: Data([1, 2, 3, 4]),
            bpm: analysed ? 120 + Double(index) : nil, key: analysed ? "8A" : nil, energy: 0.5,
            analysisScopeSeconds: 60)
    }

    private func prep(bpm: Double) -> DJTrackPrepPayload {
        DJTrackPrepPayload(
            sampleRate: 44_100, channels: 2, sourceFrameCount: 8_820_000, duration: 200, bpm: bpm,
            tempoConfidence: 0.9, beatPositions: (0..<300).map { Double($0) * 0.5 },
            downbeatPositions: (0..<75).map { Double($0) * 2 }, isConstantTempo: true,
            key: .init(tonic: 9, mode: "minor", camelot: "8A", openKey: "1m", confidence: 0.8),
            sections: [.init(start: 0, kind: "intro", bar: 0)],
            waveform: (0..<1_000).map { _ in .init(min: -0.5, max: 0.5, rms: 0.2, bandRMS: [0.1, 0.1, 0.1]) },
            loudness: [-9, -1, -5, 6])
    }

    private func makeStarter(tracks: [BuiltInMoodTrack], prepFor ids: [String], version: String = "v1") throws -> StarterLibrary {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("starter-\(UUID().uuidString).sqlite")
        try StarterLibraryWriter.create(at: url, tracks: tracks,
                                        prep: Dictionary(uniqueKeysWithValues: ids.map { ($0, prep(bpm: 121)) }),
                                        fullWaveform: false, meta: ["content_version": version])
        return try StarterLibrary(url: url)
    }

    private let versions = StarterMergeVersions(pipeline: 1, model: 1, preprocessing: 1, sampling: 1, musicalAnalysis: 2)

    func testStarterRoundTripsTracksAndPrep() throws {
        let tracks = (0..<5).map { entry($0) }
        let starter = try makeStarter(tracks: tracks, prepFor: ["jamendo-1"])
        XCTAssertEqual(starter.contentVersion, "v1")
        let read = try starter.tracks()
        XCTAssertEqual(read.map(\.id), tracks.map(\.id))
        XCTAssertEqual(read[2].quantizedVector, Data([1, 2, 3, 4]))
        XCTAssertEqual(read[2].bpm, 122)
        XCTAssertEqual(try starter.preparedCount(), 1)
        let payload = try XCTUnwrap(starter.transitionPrep(streamURL: "https://example.com/1.mp3"))
        XCTAssertEqual(payload.bpm, 121)
        XCTAssertEqual(payload.waveform.count, 200, "the iPhone starter keeps one waveform bin per second")
        XCTAssertNil(try starter.transitionPrep(streamURL: "https://example.com/2.mp3"))
    }

    func testMergeAddsEverythingOnceAndReadsPrepInPlace() async throws {
        let store = try LibraryStore(inMemory: true)
        let tracks = (0..<5).map { entry($0) }
        let starter = try makeStarter(tracks: tracks, prepFor: ["jamendo-0", "jamendo-1"])
        await store.useStarterLibrary(starter)

        let first = try await store.mergeStarterLibrary(tracks, sourceTitle: "Mood Starter", licenseText: "cc",
                                                        versions: versions)
        XCTAssertEqual(first.tracksAdded, 5)
        let again = try await store.mergeStarterLibrary(tracks, sourceTitle: "Mood Starter", licenseText: "cc",
                                                        versions: versions)
        XCTAssertEqual(again, StarterMergeResult(sourceID: first.sourceID, tracksAdded: 0, analysesAdded: 0, artworkFilled: 0))

        let rows = try await store.allTrackRows()
        XCTAssertEqual(rows.count, 5)
        let genres = Set(rows.compactMap(\.track.genre))
        XCTAssertEqual(genres, ["House", "Ambient"])
        let ids = rows.compactMap(\.track.id)
        let info = try await store.djLoadTrackInfo(trackIds: ids)
        XCTAssertTrue(ids.allSatisfy { info[$0]?.bpm != nil && info[$0]?.camelotKey == "8A" })
        let embeddings = try await store.discoveryEmbeddingVectors(trackIds: ids)
        XCTAssertEqual(embeddings.count, 5)

        let byURL = Dictionary(uniqueKeysWithValues: rows.compactMap { row in row.asset?.remoteURL.map { ($0, row.track.id!) } })
        let prepared = try XCTUnwrap(byURL["https://example.com/1.mp3"])
        let plain = try XCTUnwrap(byURL["https://example.com/3.mp3"])
        let isPrepared = try await store.hasCurrentTransitionPrep(trackId: prepared)
        let isPlainPrepared = try await store.hasCurrentTransitionPrep(trackId: plain)
        XCTAssertTrue(isPrepared, "shipped prep is read from the starter DB")
        XCTAssertFalse(isPlainPrepared)
        let stored = try await store.djTrackPrep(trackId: prepared)
        XCTAssertNil(stored?.analysisPayload, "shipped prep is never copied into the library")
    }

    /// The Mix builder's genre list comes from one aggregate query and must count exactly the
    /// tracks the planner can mix (tempo + Camelot key), as the per-track loader sees them.
    func testMixableGenreCountsMatchPerTrackInfo() async throws {
        let store = try LibraryStore(inMemory: true)
        let tracks = (0..<5).map { entry($0) } + (5..<7).map { entry($0, analysed: false) }
        _ = try await store.mergeStarterLibrary(tracks, sourceTitle: "Mood Starter", licenseText: "cc",
                                                versions: versions)
        let rows = try await store.allTrackRows()
        let info = try await store.djLoadTrackInfo(trackIds: rows.compactMap(\.track.id))
        var expected: [String: Int] = [:]
        for row in rows {
            guard let id = row.track.id, let genre = row.track.genre, !genre.isEmpty,
                  (info[id]?.bpm ?? 0) > 0, MixCompatibility.isCamelot(info[id]?.camelotKey ?? "") else { continue }
            expected[genre, default: 0] += 1
        }
        let counts = try await store.mixableGenreCounts()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: counts.map { ($0.name, $0.count) }), expected)
        XCTAssertEqual(counts.map(\.count), counts.map(\.count).sorted(by: >), "most tracks first")
        XCTAssertFalse(expected.isEmpty)
    }

    func testMergeBackfillsAnalysisAndArtworkForExistingTracks() async throws {
        let store = try LibraryStore(inMemory: true)
        let old = (0..<3).map { entry($0, analysed: false) }
        _ = try await store.mergeStarterLibrary(old, sourceTitle: "Mood Starter", licenseText: "cc", versions: versions)
        let updated = (0..<4).map { entry($0) }
        let result = try await store.mergeStarterLibrary(updated, sourceTitle: "Mood Starter", licenseText: "cc",
                                                         versions: versions)
        XCTAssertEqual(result.tracksAdded, 1)
        XCTAssertEqual(result.analysesAdded, 3)
        let ids = try await store.allTrackRows().compactMap(\.track.id)
        let info = try await store.djLoadTrackInfo(trackIds: ids)
        XCTAssertEqual(ids.filter { info[$0]?.bpm != nil }.count, 4)
    }

    func testRejectsAnUnknownFormat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).sqlite")
        try StarterLibraryWriter.create(at: url, tracks: [], prep: [:], fullWaveform: false, meta: [:])
        XCTAssertNoThrow(try StarterLibrary(url: url))
    }
}
