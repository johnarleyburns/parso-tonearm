import XCTest
import GRDB

@testable import TonearmDJ

final class DJLibraryStoreTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Helpers

    private func makeStore() throws -> (DJLibraryStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DJLibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        return (DJLibraryStore(pool: pool), dir)
    }

    private func makeFolder(named name: String, in dir: URL) throws -> URL {
        let folder = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Writes a tiny 16-bit PCM WAV so AVFoundation can read duration/metadata.
    /// `seed` makes the sample payload distinct so different files hash differently.
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
        appendLittleEndian(UInt16(1), to: &data)      // PCM
        appendLittleEndian(UInt16(1), to: &data)      // mono
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(sampleRate * 2, to: &data) // byte rate
        appendLittleEndian(UInt16(2), to: &data)      // block align
        appendLittleEndian(UInt16(16), to: &data)     // bits per sample
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

    /// Seeds two tracks sharing one artist + album (the §18.2 JOIN shape).
    private func seedLibrary(in db: Database) throws {
        var artist = DJArtist(syncID: UUID().uuidString, name: "Orbital",
                              sortName: "Orbital", createdAt: fixedDate)
        try artist.insert(db)
        var album = DJAlbum(syncID: UUID().uuidString, title: "Snivilisation",
                            createdAt: fixedDate)
        try album.insert(db)

        var halcyon = DJTrack(syncID: UUID().uuidString, albumID: album.id,
                              title: "Halcyon + On + On", contentHash: "h-alcyon",
                              sortKey: "halcyon", addedAt: fixedDate, updatedAt: fixedDate)
        try halcyon.insert(db)
        try db.execute(sql: "INSERT INTO track_artist (trackID, artistID, role, position) VALUES (?, ?, 'primary', 0)",
                       arguments: [halcyon.id!, artist.id!])

        var chime = DJTrack(syncID: UUID().uuidString, albumID: album.id,
                            title: "Chime", contentHash: "h-chime",
                            sortKey: "chime", addedAt: fixedDate, updatedAt: fixedDate)
        try chime.insert(db)
        try db.execute(sql: "INSERT INTO track_artist (trackID, artistID, role, position) VALUES (?, ?, 'primary', 1)",
                       arguments: [chime.id!, artist.id!])
    }

    // MARK: - Import

    func testImportFolderAddsTracksAssetsAndFolder() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(named: "Music", in: dir)
        _ = try makeWAV(named: "alpha.wav", in: folder, seed: 1)
        _ = try makeWAV(named: "beta.wav", in: folder, seed: 2)

        let summary = try await store.importFolder(folder)
        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.skipped, 0)

        let rows = try await store.tracks(matching: LibraryQuery())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.title)), Set(["alpha", "beta"]))
        XCTAssertEqual(rows.allSatisfy { $0.analysisState == "pending" }, true)
        let count = try await store.trackCount()
        XCTAssertEqual(count, 2)
        let folders = try await store.folders()
        XCTAssertEqual(folders.count, 1)

        let assets = try await store.pool.read { try DJAsset.fetchAll($0) }
        XCTAssertEqual(assets.count, 2)
        XCTAssertNotNil(assets.first?.bookmark)
    }

    func testReimportSkipsAlreadyTrackedFiles() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(named: "Music", in: dir)
        _ = try makeWAV(named: "alpha.wav", in: folder)

        let first = try await store.importFolder(folder)
        XCTAssertEqual(first.added, 1)

        let second = try await store.importFolder(folder)
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.skipped, 1)
        let count = try await store.trackCount()
        XCTAssertEqual(count, 1)
        let folders = try await store.folders()
        XCTAssertEqual(folders.count, 1)
    }

    func testImportFolderRecordsRelPathForSubfolders() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(named: "Music", in: dir)
        let ep = folder.appendingPathComponent("EP1", isDirectory: true)
        try FileManager.default.createDirectory(at: ep, withIntermediateDirectories: true)
        _ = try makeWAV(named: "gamma.wav", in: ep, seed: 3)

        _ = try await store.importFolder(folder, includeSubfolders: true)
        let assets = try await store.pool.read { try DJAsset.fetchAll($0) }
        XCTAssertEqual(assets.first?.relPath, "EP1/gamma.wav")
    }

    func testImportFolderWithNoAudioThrows() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(named: "Empty", in: dir)
        try Data("hello".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        do {
            _ = try await store.importFolder(folder)
            XCTFail("expected DJImportError.noAudioFiles")
        } catch let error as DJImportError {
            guard case .noAudioFiles = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    // MARK: - Listing SQL (§18.2)

    func testTrackRowJoinsArtistNamesAndAlbumTitle() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DJLibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        try pool.write { try self.seedLibrary(in: $0) }

        let repo = DJTrackRepository(pool: pool)
        let rows = try repo.tracks(matching: LibraryQuery())
        XCTAssertEqual(rows.count, 2)
        let halcyon = try XCTUnwrap(rows.first { $0.title == "Halcyon + On + On" })
        XCTAssertEqual(halcyon.artistNames, "Orbital")
        XCTAssertEqual(halcyon.albumTitle, "Snivilisation")
    }

    func testSearchFiltersByTitleArtistAndAlbum() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DJLibraryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DJDatabase.open(at: dir.appendingPathComponent("tonearm-dj.sqlite"))
        try pool.write { try self.seedLibrary(in: $0) }

        let repo = DJTrackRepository(pool: pool)
        XCTAssertEqual(try repo.tracks(matching: LibraryQuery(searchText: "halcyon")).count, 1)
        XCTAssertEqual(try repo.tracks(matching: LibraryQuery(searchText: "orbital")).count, 2)
        XCTAssertEqual(try repo.tracks(matching: LibraryQuery(searchText: "snivilisation")).count, 2)
        XCTAssertEqual(try repo.tracks(matching: LibraryQuery(searchText: "nomatch")).count, 0)
        XCTAssertEqual(try repo.tracks(matching: LibraryQuery(analysisState: "ready")).count, 0)
        XCTAssertEqual(try repo.tracks(matching: LibraryQuery(analysisState: "pending")).count, 2)
    }

    // MARK: - Observation (§18.3)

    @MainActor
    func testObserveTracksEmitsInitialAndLiveRows() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = try makeFolder(named: "Music", in: dir)
        _ = try makeWAV(named: "alpha.wav", in: folder, seed: 1)
        let box = EmissionsBox()
        let stream = store.observeTracks(LibraryQuery())
        let task = Task { for await rows in stream { box.emissions.append(rows) } }
        defer { task.cancel() }

        _ = try await store.importFolder(folder)
        try await poll { box.emissions.last?.count == 1 }
        XCTAssertEqual(box.emissions.last?.count, 1)

        _ = try makeWAV(named: "beta.wav", in: folder, seed: 2)
        _ = try await store.importFolder(folder)
        try await poll { box.emissions.last?.count == 2 }
        XCTAssertEqual(box.emissions.last?.count, 2)
    }
}

@MainActor
private final class EmissionsBox {
    var emissions: [[DJTrackRow]] = []
}

@MainActor
private func poll(timeout: TimeInterval = 5, _ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("poll timed out")
}
