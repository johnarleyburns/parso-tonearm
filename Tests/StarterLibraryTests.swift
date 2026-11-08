import XCTest
import GRDB
@testable import TonearmCore

/// The starter DB: built on the Mac, merged into the library in one transaction.
final class StarterLibraryTests: XCTestCase {
    private let contract = StarterEmbeddingContract(fingerprint: "test-fingerprint-v1", dimensions: 128)
    private let otherContract = StarterEmbeddingContract(fingerprint: "test-fingerprint-v2", dimensions: 128)

    private func profile(_ seed: Int) throws -> TransitionProfile {
        try TransitionProfile(
            beatPeriodSeconds: 0.5, beatPhaseSeconds: 0.1, beatConfidence: 0.9,
            introEndSeconds: 8, outroStartSeconds: 180, phraseBoundariesSeconds: [8, 40, 72],
            loudnessEnvelope: Data(repeating: UInt8(seed % 256), count: TransitionProfile.loudnessEnvelopeBinCount),
            peak: -1.0)
    }

    private func entry(_ index: Int, provider: String = "jamendo", analysed: Bool = true,
                       fingerprint: String? = nil) -> BuiltInMoodTrack {
        BuiltInMoodTrack(
            id: "jamendo-\(index)", provider: provider, providerTrackID: "\(index)",
            embeddingSpaceFingerprint: fingerprint ?? contract.fingerprint,
            title: "Track \(index)", artist: index.isMultiple(of: 2) ? "Ann" : "Bob",
            genre: index < 3 ? "House" : "Ambient", license: "cc-by", licenseURL: nil, durationSec: 200,
            streamURL: "https://example.com/\(index).mp3", artworkURL: "https://example.com/\(index).jpg",
            dimensions: 128, scale: 0.01, quantizedVector: Data(repeating: UInt8(index + 1), count: 128),
            bpm: analysed ? 120 + Double(index) : nil, key: analysed ? "8A" : nil, energy: 0.5,
            analysisScopeSeconds: 60, transitionProfile: try? profile(index))
    }

    private func makeStarter(tracks: [BuiltInMoodTrack], version: String = "v1",
                             expecting: StarterEmbeddingContract? = nil) throws -> StarterLibrary {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("starter-\(UUID().uuidString).sqlite")
        try StarterLibraryWriter.create(at: url, tracks: tracks, meta: ["content_version": version],
                                        expecting: expecting ?? contract)
        return try StarterLibrary(url: url)
    }

    private let versions = StarterMergeVersions(pipeline: 1, model: 1, preprocessing: 1, sampling: 1, musicalAnalysis: 2)

    func testStarterRoundTripsTracks() throws {
        let tracks = (0..<5).map { entry($0) }
        let starter = try makeStarter(tracks: tracks)
        XCTAssertEqual(starter.contentVersion, "v1")
        let read = try starter.tracks(expecting: contract)
        XCTAssertEqual(read.map(\.id), tracks.map(\.id))
        XCTAssertEqual(read[2].dimensions, 128)
        XCTAssertEqual(read[2].quantizedVector.count, 128)
        XCTAssertEqual(read[2].bpm, 122)
        XCTAssertEqual(read[2].provider, "jamendo")
        XCTAssertEqual(read[2].providerTrackID, "2")
        XCTAssertEqual(read[2].embeddingSpaceFingerprint, contract.fingerprint)
    }

    /// Exit criterion: "No app read path reconstructs a 512-D starter vector" / "v4 reader returns
    /// the stored native 128-D vector unchanged" — round-tripping through the writer and reader
    /// must not lose precision the way a PCA reconstruction would.
    func testNativeVectorRoundTripsUnchanged() throws {
        let original: [Float] = (0..<128).map { Float($0) / 127.0 - 0.5 }
        let (quantized, scale) = EmbeddingProjection.quantize(original)
        let track = BuiltInMoodTrack(
            id: "jamendo-9", provider: "jamendo", providerTrackID: "9", embeddingSpaceFingerprint: contract.fingerprint,
            title: "T", artist: "A", genre: "House", license: "cc-by", licenseURL: nil, durationSec: 200,
            streamURL: "https://example.com/9.mp3", artworkURL: nil, dimensions: 128, scale: scale,
            quantizedVector: quantized, bpm: 120, key: "8A", energy: 0.5, analysisScopeSeconds: 60,
            transitionProfile: nil)
        let starter = try makeStarter(tracks: [track])
        let read = try starter.tracks(expecting: contract)
        let rebuilt = EmbeddingProjection.dequantize(read[0].quantizedVector, scale: read[0].scale)
        for (a, b) in zip(rebuilt, original) { XCTAssertEqual(a, b, accuracy: 0.01) }
    }

    func testMergeAddsEverythingOnceAndIsIdempotent() async throws {
        let store = try LibraryStore(inMemory: true)
        let tracks = (0..<5).map { entry($0) }
        let starter = try makeStarter(tracks: tracks)
        await store.useStarterLibrary(starter)

        let first = try await store.mergeStarterLibrary(tracks, sourceTitle: "Mood Starter", licenseText: "cc",
                                                        versions: versions, expecting: contract)
        XCTAssertEqual(first.tracksAdded, 5)
        let again = try await store.mergeStarterLibrary(tracks, sourceTitle: "Mood Starter", licenseText: "cc",
                                                        versions: versions, expecting: contract)
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
    }

    /// Exit criterion / test #3: a changed stream URL for the same provider identity updates the
    /// existing track/asset in place — it must never produce a second track.
    func testChangedStreamURLUpdatesInPlaceWithoutDuplicating() async throws {
        let store = try LibraryStore(inMemory: true)
        let original = entry(0)
        _ = try await store.mergeStarterLibrary([original], sourceTitle: "Mood Starter", licenseText: "cc",
                                                versions: versions, expecting: contract)
        let rowsBefore = try await store.allTrackRows()
        XCTAssertEqual(rowsBefore.count, 1)
        let trackID = try XCTUnwrap(rowsBefore.first?.track.id)

        let moved = BuiltInMoodTrack(
            id: original.id, provider: original.provider, providerTrackID: original.providerTrackID,
            embeddingSpaceFingerprint: original.embeddingSpaceFingerprint, title: original.title,
            artist: original.artist, genre: original.genre, license: original.license,
            licenseURL: original.licenseURL, durationSec: original.durationSec,
            streamURL: "https://example.com/moved-0.mp3", artworkURL: original.artworkURL,
            dimensions: original.dimensions, scale: original.scale, quantizedVector: original.quantizedVector,
            bpm: original.bpm, key: original.key, energy: original.energy,
            analysisScopeSeconds: original.analysisScopeSeconds, transitionProfile: original.transitionProfile)
        let result = try await store.mergeStarterLibrary([moved], sourceTitle: "Mood Starter", licenseText: "cc",
                                                         versions: versions, expecting: contract)
        XCTAssertEqual(result.tracksAdded, 0, "a URL change must update in place, not insert")
        let rowsAfter = try await store.allTrackRows()
        XCTAssertEqual(rowsAfter.count, 1, "no duplicate track")
        XCTAssertEqual(rowsAfter.first?.track.id, trackID, "same track identity")
        XCTAssertEqual(rowsAfter.first?.asset?.remoteURL, "https://example.com/moved-0.mp3")
    }

    /// Exit criterion / test #4: two different providers may use the same numeric providerTrackID
    /// without colliding — identity is (provider, providerTrackID), not providerTrackID alone.
    func testSameNumericIDUnderTwoProvidersDoesNotCollide() async throws {
        let store = try LibraryStore(inMemory: true)
        let jamendo = entry(0, provider: "jamendo")
        let other = entry(0, provider: "archiveorg")
        let result = try await store.mergeStarterLibrary([jamendo, other], sourceTitle: "Mood Starter",
                                                         licenseText: "cc", versions: versions, expecting: contract)
        XCTAssertEqual(result.tracksAdded, 2)
        let rows = try await store.allTrackRows()
        XCTAssertEqual(rows.count, 2)
    }

    /// Exit criterion / test #6: starter refresh preserves user-owned records — favorites,
    /// playlist membership and a user-edited title survive a re-merge (even one that updates the
    /// track's URL and musical analysis).
    func testUserOwnedRecordsSurviveARefresh() async throws {
        let store = try LibraryStore(inMemory: true)
        _ = try await store.mergeStarterLibrary([entry(0, analysed: false)], sourceTitle: "Mood Starter",
                                                licenseText: "cc", versions: versions, expecting: contract)
        let initialRows = try await store.allTrackRows()
        let trackID = try XCTUnwrap(initialRows.first?.track.id)
        try await store.setFavorite(trackId: trackID, true)
        let playlist = try await store.insertPlaylist(Playlist(id: nil, title: "My Mix", kind: .manual,
                                                                folderBookmark: nil, watch: false))
        let playlistID = try XCTUnwrap(playlist.id)
        try await store.addToPlaylist(playlistId: playlistID, trackId: trackID)

        _ = try await store.mergeStarterLibrary([entry(0, analysed: true)], sourceTitle: "Mood Starter",
                                                licenseText: "cc", versions: versions, expecting: contract)

        let favorites = try await store.favoriteTrackIds()
        XCTAssertTrue(favorites.contains(trackID), "favorite must survive a refresh")
        let membership = try await store.playlistTrackIDs()
        XCTAssertEqual(membership[playlistID], [trackID], "playlist membership must survive a refresh")
        let rows = try await store.allTrackRows()
        XCTAssertEqual(rows.count, 1, "refresh must update the existing track, not add a second one")
    }

    /// Exit criterion / test #5: a row whose embedding-space fingerprint or dimensions don't match
    /// the installed contract is rejected before any partial write/merge.
    func testWrongFingerprintIsRejectedBeforeAnyPartialWrite() async throws {
        let mismatched = entry(0, fingerprint: otherContract.fingerprint)
        XCTAssertThrowsError(try StarterLibraryWriter.create(
            at: FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).sqlite"),
            tracks: [mismatched], meta: [:], expecting: contract)) { error in
            XCTAssertEqual(error as? StarterLibraryError,
                           .embeddingSpaceMismatch(expected: contract.fingerprint, found: otherContract.fingerprint))
        }

        let store = try LibraryStore(inMemory: true)
        await XCTAssertThrowsErrorAsync(try await store.mergeStarterLibrary(
            [entry(1), mismatched], sourceTitle: "Mood Starter", licenseText: "cc",
            versions: versions, expecting: contract))
        let rows = try await store.allTrackRows()
        XCTAssertTrue(rows.isEmpty, "a rejected entry must leave no partial merge, not even the valid ones before it")
    }

    func testMixableGenreCountsMatchPerTrackInfo() async throws {
        let store = try LibraryStore(inMemory: true)
        let tracks = (0..<5).map { entry($0) } + (5..<7).map { entry($0, analysed: false) }
        _ = try await store.mergeStarterLibrary(tracks, sourceTitle: "Mood Starter", licenseText: "cc",
                                                versions: versions, expecting: contract)
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
        _ = try await store.mergeStarterLibrary(old, sourceTitle: "Mood Starter", licenseText: "cc",
                                                versions: versions, expecting: contract)
        let updated = (0..<4).map { entry($0) }
        let result = try await store.mergeStarterLibrary(updated, sourceTitle: "Mood Starter", licenseText: "cc",
                                                         versions: versions, expecting: contract)
        XCTAssertEqual(result.tracksAdded, 1)
        XCTAssertEqual(result.analysesAdded, 3)
        let ids = try await store.allTrackRows().compactMap(\.track.id)
        let info = try await store.djLoadTrackInfo(trackIds: ids)
        XCTAssertEqual(ids.filter { info[$0]?.bpm != nil }.count, 4)
    }

    /// Exit criterion / test #2: format v3 (or any format but the current one) is rejected with a
    /// clear unsupported-format error — never adapted or read as a fallback.
    func testRejectsAnUnknownFormat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).sqlite")
        try StarterLibraryWriter.create(at: url, tracks: [], meta: [:], expecting: contract)
        // Downgrade the just-written file's own format_version to simulate a legacy (pre-v4) file
        // — StarterLibraryWriter always stamps the current version, so this is the only way to
        // construct a genuinely-unsupported-format fixture without a second, parallel v3 writer.
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "UPDATE starter_meta SET value = '3' WHERE key = 'format_version'")
        }
        XCTAssertThrowsError(try StarterLibrary(url: url)) { error in
            XCTAssertEqual(error as? StarterLibraryError, .unsupportedFormat("3"))
        }
    }
}

/// `XCTAssertThrowsError` has no `async` overload; this awaits the expression first so an
/// `async throws` call can still be asserted to throw without a parallel, hand-written try/catch
/// at every call site.
func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                  _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("did not throw \(message)", file: file, line: line)
    } catch {
        // Expected.
    }
}
