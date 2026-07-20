import XCTest
@testable import TonearmCore

@MainActor
final class WatchCatalogTests: XCTestCase {

    func testKeyGeneration() {
        XCTAssertEqual(WatchCatalog.key(for: 42), "t42")
        XCTAssertEqual(WatchCatalog.albumKey(for: 7), "a7")
        XCTAssertEqual(WatchCatalog.playlistKey(for: 1), "p1")
        XCTAssertEqual(WatchCatalog.artistKey(for: 3), "ar3")
        XCTAssertEqual(WatchCatalog.sourceKey(), "iPhone")
    }

    func testExportEmptyLibrary() async throws {
        let store = try LibraryStore(inMemory: true)
        let catalog = try await WatchCatalog.export(from: store)
        XCTAssertEqual(catalog.tracks.count, 0)
        XCTAssertEqual(catalog.albums.count, 0)
        XCTAssertEqual(catalog.playlists.count, 0)
        XCTAssertEqual(catalog.artists.count, 0)
        XCTAssertGreaterThan(catalog.version, 0)
    }

    func testExportWithTracks() async throws {
        let store = try LibraryStore(inMemory: true)
        let src = try await store.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
            title: "Test", addedAt: Date(), lastResolvedAt: Date(),
            followUpdates: false, licenseText: nil, memberCapHit: false))

        guard let sourceId = src.id else { XCTFail("no source id"); return }

        let album = try await store.insertAlbum(Album(
            id: nil, sourceId: sourceId, title: "Album One",
            artist: "Artist A", year: 2024))

        let artist = try await store.findOrCreateArtist(name: "Artist A", sortName: "Artist A")
        guard let artistId = artist.id else { XCTFail("no artist id"); return }

        let track = try await store.insertTrack(Track(
            id: nil, albumId: album.id, sourceId: sourceId,
            title: "Song 1", trackNo: 1, discNo: nil,
            durationSec: 240, codec: "MP3", sampleRate: nil,
            bitDepthOrBitrate: nil, sortKey: "001",
            artistId: artistId))

        let catalog = try await WatchCatalog.export(from: store)

        XCTAssertEqual(catalog.tracks.count, 1)
        XCTAssertEqual(catalog.albums.count, 1)
        XCTAssertEqual(catalog.artists.count, 1)

        let dto = catalog.tracks[0]
        XCTAssertEqual(dto.key, WatchCatalog.key(for: track.id ?? -1))
        XCTAssertEqual(dto.title, "Song 1")
        XCTAssertEqual(dto.artist, "Artist A")
        XCTAssertEqual(dto.albumKey, WatchCatalog.albumKey(for: album.id ?? -1))
    }

    func testRoundTripCatalogImport() async throws {
        let source = try LibraryStore(inMemory: true)
        let dest = try LibraryStore(inMemory: true)

        // Build source library
        let src = try await source.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
            title: "Source", addedAt: Date(), lastResolvedAt: Date(),
            followUpdates: false, licenseText: nil, memberCapHit: false))
        guard let sourceId = src.id else { XCTFail("no source id"); return }

        let album = try await source.insertAlbum(Album(
            id: nil, sourceId: sourceId, title: "Album", artist: "Artist", year: 2024))
        let artist = try await source.findOrCreateArtist(name: "Artist", sortName: "Artist")

        let t1 = try await source.insertTrack(Track(
            id: nil, albumId: album.id, sourceId: sourceId, title: "Track 1",
            trackNo: 1, discNo: nil, durationSec: 200, codec: "MP3",
            sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "001",
            artistId: artist.id))
        let t2 = try await source.insertTrack(Track(
            id: nil, albumId: album.id, sourceId: sourceId, title: "Track 2",
            trackNo: 2, discNo: nil, durationSec: 180, codec: "MP3",
            sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "002",
            artistId: artist.id))

        // Export
        let catalog = try await WatchCatalog.export(from: source)
        XCTAssertEqual(catalog.tracks.count, 2)

        // Import into dest
        let result = try await WatchCatalog.import(catalog, into: dest)
        XCTAssertEqual(result.upsertedTracks, 2)
        XCTAssertEqual(result.upsertedAlbums, 1)
        XCTAssertEqual(result.upsertedArtists, 1)

        // Verify dest
        let destTracks = try await dest.allTracks()
        XCTAssertEqual(destTracks.count, 2)
        XCTAssertEqual(destTracks[0].syncID, WatchCatalog.key(for: t1.id ?? -1))
        XCTAssertEqual(destTracks[1].syncID, WatchCatalog.key(for: t2.id ?? -1))
    }

    func testStaleCatalogRejection() {
        let catalog = WatchCatalogSnapshot(version: 5, playlists: [], albums: [], artists: [], tracks: [])
        XCTAssertTrue(WatchCatalog.isStale(catalog, lastVersion: 5))
        XCTAssertTrue(WatchCatalog.isStale(catalog, lastVersion: 10))
        XCTAssertFalse(WatchCatalog.isStale(catalog, lastVersion: 4))
    }

    func testIdempotentImport() async throws {
        let source = try LibraryStore(inMemory: true)
        let dest = try LibraryStore(inMemory: true)

        let src = try await source.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
            title: "Source", addedAt: Date(), lastResolvedAt: Date(),
            followUpdates: false, licenseText: nil, memberCapHit: false))
        guard let sourceId = src.id else { XCTFail("no source id"); return }

        _ = try await source.insertTrack(Track(
            id: nil, albumId: nil, sourceId: sourceId, title: "Track",
            trackNo: 1, discNo: nil, durationSec: 200, codec: "MP3",
            sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "001"))

        let catalog = try await WatchCatalog.export(from: source)

        // Import twice
        let r1 = try await WatchCatalog.import(catalog, into: dest)
        let r2 = try await WatchCatalog.import(catalog, into: dest)

        // Second import should not create duplicates
        XCTAssertEqual(r2.upsertedTracks, 0, "re-import should be idempotent")
        let tracks = try await dest.allTracks()
        XCTAssertEqual(tracks.count, 1)
    }

    func testDeleteStaleTracksOnImport() async throws {
        let source = try LibraryStore(inMemory: true)
        let dest = try LibraryStore(inMemory: true)

        let src = try await source.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
            title: "Source", addedAt: Date(), lastResolvedAt: Date(),
            followUpdates: false, licenseText: nil, memberCapHit: false))
        guard let sourceId = src.id else { XCTFail("no source id"); return }

        _ = try await source.insertTrack(Track(
            id: nil, albumId: nil, sourceId: sourceId, title: "Track A",
            trackNo: 1, discNo: nil, durationSec: 200, codec: "MP3",
            sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "001"))
        _ = try await source.insertTrack(Track(
            id: nil, albumId: nil, sourceId: sourceId, title: "Track B",
            trackNo: 2, discNo: nil, durationSec: 180, codec: "MP3",
            sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "002"))

        let catalog1 = try await WatchCatalog.export(from: source)
        _ = try await WatchCatalog.import(catalog1, into: dest)

        // Now remove Track B from source (delete track, re-export)
        let allTracks = try await source.allTracks()
        if let b = allTracks.first(where: { $0.title == "Track B" }), let bid = b.id {
            try await source.deleteTrack(id: bid)
        }
        let catalog2 = try await WatchCatalog.export(from: source)
        let result = try await WatchCatalog.import(catalog2, into: dest)

        XCTAssertEqual(result.deletedTracks, 1, "removed track should be deleted")
        let destTracks = try await dest.allTracks()
        XCTAssertEqual(destTracks.count, 1)
        XCTAssertEqual(destTracks[0].title, "Track A")
    }

    func testImportCreatesIPhoneSource() async throws {
        let store = try LibraryStore(inMemory: true)
        let catalog = WatchCatalogSnapshot(version: 1, playlists: [], albums: [], artists: [], tracks: [])
        _ = try await WatchCatalog.import(catalog, into: store)

        let sources = try await store.allSources()
        XCTAssertTrue(sources.contains(where: { $0.title == "iPhone" }),
                      "import should create the 'iPhone' synthetic source")
    }

    func testCatalogUpdateModifiesTracks() async throws {
        let source = try LibraryStore(inMemory: true)
        let dest = try LibraryStore(inMemory: true)

        let src = try await source.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
            title: "Source", addedAt: Date(), lastResolvedAt: Date(),
            followUpdates: false, licenseText: nil, memberCapHit: false))
        guard let sourceId = src.id else { XCTFail("no source id"); return }

        _ = try await source.insertTrack(Track(
            id: nil, albumId: nil, sourceId: sourceId, title: "Original Name",
            trackNo: 1, discNo: nil, durationSec: 200, codec: "MP3",
            sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "001"))

        let catalog1 = try await WatchCatalog.export(from: source)
        _ = try await WatchCatalog.import(catalog1, into: dest)

        // Change title in source
        let tracks = try await source.allTracks()
        guard var t = tracks.first, let tid = t.id else { XCTFail("no track"); return }
        t.title = "Updated Name"
        _ = try await source.updateTrack(t)

        let catalog2 = try await WatchCatalog.export(from: source)
        let result = try await WatchCatalog.import(catalog2, into: dest)

        XCTAssertEqual(result.upsertedTracks, 1, "changed track should be upserted")
        let destTracks = try await dest.allTracks()
        XCTAssertEqual(destTracks[0].title, "Updated Name")
    }
}
