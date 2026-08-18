import GRDB
import XCTest
@testable import TonearmCore
@testable import TonearmDJ

final class PlaylistCrateImporterTests: XCTestCase {
    func testImportsOnlyOnDeviceTracksInPlaylistOrderAndReportsSkipped() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let result = try await fixture.importer.importCrate(
            playlistID: fixture.playlistID, title: "Set")

        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.source.title, "Set")
        let stored = try await fixture.djStore.pool.read { db in
            let playlist = try XCTUnwrap(DJPlaylist.filter(Column("title") == "Set").fetchOne(db))
            let items = try DJPlaylistItem
                .filter(Column("playlistID") == playlist.id!)
                .order(Column("position")).fetchAll(db)
            return (try DJPlaylist.fetchCount(db), items.map(\.trackID))
        }
        XCTAssertEqual(stored.0, 1)
        XCTAssertEqual(stored.1.count, 2)
    }

    func testReimportReplacesTheNamedCrateInsteadOfStacking() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.importer.importCrate(playlistID: fixture.playlistID, title: "Set")
        _ = try await fixture.importer.importCrate(playlistID: fixture.playlistID, title: "Set")

        let counts = try await fixture.djStore.pool.read { db in
            let playlist = try XCTUnwrap(DJPlaylist.filter(Column("title") == "Set").fetchOne(db))
            return (try DJPlaylist.fetchCount(db),
                    try DJPlaylistItem.filter(Column("playlistID") == playlist.id!).fetchCount(db))
        }
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 2)
    }

    private struct Fixture {
        let directory: URL
        let djStore: DJLibraryStore
        let importer: PlaylistCrateImporter
        let playlistID: Int64
    }

    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaylistCrateImporterTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstURL = directory.appendingPathComponent("one.wav")
        let secondURL = directory.appendingPathComponent("two.wav")
        try Data([1, 2, 3]).write(to: firstURL)
        try Data([4, 5, 6]).write(to: secondURL)

        let library = try LibraryStore(inMemory: true)
        let source = try await library.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Fixture",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let localOne = try await insertTrack(title: "One", source: source, assetURL: firstURL,
                                             remoteURL: nil, store: library)
        let remote = try await insertTrack(title: "Remote", source: source, assetURL: nil,
                                           remoteURL: "https://example.invalid/\(UUID().uuidString).wav",
                                           store: library)
        let localTwo = try await insertTrack(title: "Two", source: source, assetURL: secondURL,
                                             remoteURL: nil, store: library)
        let playlist = try await library.createManualPlaylist(
            title: "Set", trackIds: [localOne.id!, remote.id!, localTwo.id!])

        let djStore = try DJLibraryStore(path: directory.appendingPathComponent("dj.sqlite"))
        return Fixture(directory: directory, djStore: djStore,
                       importer: PlaylistCrateImporter(library: library, djLibrary: djStore),
                       playlistID: playlist.id!)
    }

    private func insertTrack(title: String, source: Source, assetURL: URL?, remoteURL: String?,
                             store: LibraryStore) async throws -> Track {
        let track = try await store.insertTrack(Track(
            id: nil, albumId: nil, sourceId: source.id!, title: title, trackNo: nil,
            discNo: nil, durationSec: 1, codec: "WAV", sampleRate: 44_100,
            bitDepthOrBitrate: nil, sortKey: title))
        _ = try await store.insertAsset(Asset(
            id: nil, trackId: track.id!, kind: assetURL == nil ? .remote : .localRef,
            bookmark: assetURL.flatMap(BookmarkVault.makeBookmark), relPath: nil,
            remoteURL: remoteURL, altRemoteURL: nil,
            sizeBytes: nil, unsupportedReason: nil))
        return track
    }
}
