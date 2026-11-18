import Testing
@testable import TonearmWatchCore
@testable import TonearmWatchProtocol

@Suite struct WatchLocalCatalogSearchTests {
    private let tracks = [
        WatchTrackSnapshot(id: "ready", title: "Ready Song", artist: "Artist", albumTitle: "Album",
                           durationSeconds: 10, trackNumber: 1, discNumber: 1, artworkID: nil,
                           codec: "mp3", phoneRevision: 1, localFilename: "ready.mp3",
                           isReady: true),
        WatchTrackSnapshot(id: "catalog", title: "Catalog Song", artist: "Artist", albumTitle: "Album",
                           durationSeconds: 11, trackNumber: 2, discNumber: 1, artworkID: nil,
                           codec: "mp3", phoneRevision: 1, localFilename: nil, isReady: false)
    ]

    @Test func testAllMusicFindsCatalogMetadataAndMarksOnlyValidatedAsset() {
        let rows = WatchLocalCatalogSearch.rows(query: "song", tracks: tracks, playlists: [], onWatchOnly: false)
        #expect(rows.contains { $0.id == "catalog" && !$0.isDownloadedOnWatch })
        #expect(rows.contains { $0.id == "ready" && $0.isDownloadedOnWatch })
    }

    @Test func testThisWatchExcludesMetadataWithoutAudio() {
        let rows = WatchLocalCatalogSearch.rows(query: "song", tracks: tracks, playlists: [], onWatchOnly: true)
        #expect(rows.contains { $0.id == "ready" })
        #expect(!rows.contains { $0.id == "catalog" })
    }

    @Test func testCatalogPageRoundTripsAllPagesAndMembership() throws {
        let page = WatchLibraryPage(
            catalogID: "catalog-1", revision: 4, pageIndex: 0, pageCount: 2,
            tracks: [WatchTrackSummary(trackID: WatchTrackID("catalog"), title: "Catalog Song")],
            playlists: [WatchLibraryPlaylist(playlistID: "playlist", title: "Road Mix",
                                              trackIDs: [WatchTrackID("catalog")])])
        let data = try JSONEncoder().encode(page)
        #expect(try JSONDecoder().decode(WatchLibraryPage.self, from: data) == page)
        #expect(page.playlists.first?.trackIDs == [WatchTrackID("catalog")])
    }
}
