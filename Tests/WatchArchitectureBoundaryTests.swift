import XCTest
@testable import TonearmWatchProtocol
@testable import TonearmWatchLegacyCore

final class WatchArchitectureBoundaryTests: XCTestCase {
    func testProtocolIdentityAndPlaybackTargetAreStable() {
        let id: WatchTrackID = "track-stable-id"
        XCTAssertEqual(id.rawValue, "track-stable-id")
        XCTAssertEqual(WatchProtocolVersion.current, 1)
        XCTAssertEqual(WatchPlaybackTarget.iPhone.userFacingName, "iPhone")
        XCTAssertEqual(WatchPlaybackTarget.watch.userFacingName, "Apple Watch")
    }

    func testLegacyStoreImportsCatalogWithoutPhoneCore() async throws {
        let store = try LegacyWatchLibraryStore(inMemory: true)
        let snapshot = WatchCatalogSnapshot(
            version: 1,
            playlists: [.init(key: "playlist-1", title: "Set", trackKeys: ["track-1"])],
            albums: [.init(key: "album-1", title: "Record", artist: "Artist")],
            artists: [.init(key: "artist-1", name: "Artist")],
            tracks: [.init(key: "track-1", title: "Song", artist: "Artist", artistKey: "artist-1", albumKey: "album-1", sortKey: "song")])
        try await store.importCatalog(snapshot)
        let tracks = try await store.allTracks()
        let playlists = try await store.allPlaylists()
        let playlistID = try XCTUnwrap(playlists.first?.id)
        let rows = try await store.playlistTrackRows(playlistId: playlistID)
        XCTAssertEqual(tracks.map(\.syncID), ["track-1"])
        XCTAssertEqual(rows.map(\.row.track.title), ["Song"])
        let migration = try await store.migrationSnapshot()
        XCTAssertEqual(migration.tracks.map(\.trackID), ["track-1"])
        XCTAssertEqual(migration.playlists.first?.trackIDs, ["track-1"])
    }
}
