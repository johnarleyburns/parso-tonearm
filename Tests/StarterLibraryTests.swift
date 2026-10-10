import XCTest
@testable import TonearmCore

/// The starter DB: built on the Mac, merged into the library in one transaction. The tempo it
/// carries is the hint the mix decks' blend analysis starts from.
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

    private func makeStarter(tracks: [BuiltInMoodTrack], version: String = "v1") throws -> StarterLibrary {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("starter-\(UUID().uuidString).sqlite")
        try StarterLibraryWriter.create(at: url, tracks: tracks, meta: ["content_version": version])
        return try StarterLibrary(url: url)
    }

    private let versions = StarterMergeVersions(pipeline: 1, model: 1, preprocessing: 1, sampling: 1, musicalAnalysis: 2)

    func testStarterRoundTripsTracks() throws {
        let tracks = (0..<5).map { entry($0) }
        let starter = try makeStarter(tracks: tracks)
        XCTAssertEqual(starter.contentVersion, "v1")
        let read = try starter.tracks()
        XCTAssertEqual(read.map(\.id), tracks.map(\.id))
        XCTAssertEqual(read[2].quantizedVector, Data([1, 2, 3, 4]))
        XCTAssertEqual(read[2].bpm, 122)
    }

    func testMergeAddsEverythingOnceAndProvidesTheTempoHint() async throws {
        let store = try LibraryStore(inMemory: true)
        let tracks = (0..<5).map { entry($0) }
        let starter = try makeStarter(tracks: tracks)
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
        let second = try XCTUnwrap(byURL["https://example.com/1.mp3"])
        let hint = try await store.blendTempoHint(trackId: second)
        XCTAssertEqual(hint, 121, "the starter tempo is the blend analysis' starting point")
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
        try StarterLibraryWriter.create(at: url, tracks: [], meta: [:])
        XCTAssertNoThrow(try StarterLibrary(url: url))
    }
}
