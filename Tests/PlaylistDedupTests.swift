import GRDB
import Testing
@testable import TonearmCore

@Suite struct PlaylistDedupTests {
    @Test func testFirstOccurrenceWinsAndPositionsBecomeContiguous() {
        let items = [
            PlaylistItem(id: 10, playlistId: 1, position: 4, trackId: 7, sectionTitle: nil),
            PlaylistItem(id: 11, playlistId: 1, position: 8, trackId: 8, sectionTitle: nil),
            PlaylistItem(id: 12, playlistId: 1, position: 9, trackId: 7, sectionTitle: nil),
        ]
        #expect(PlaylistDedup.duplicateItemIDs(in: items) == [12])
        #expect(PlaylistDedup.deduplicated(items).map(\.id) == [10, 11])
        #expect(PlaylistDedup.deduplicated(items).map(\.position) == [0, 1])
    }

    @Test func testStoreDoesNotAddTheSameTrackTwice() async throws {
        let store = try LibraryStore(inMemory: true)
        let track = try await insertTrack(store: store, title: "One")
        let playlist = try await store.createManualPlaylist(title: "Set", trackIds: [])
        try await store.addToPlaylist(playlistId: try #require(playlist.id), trackId: try #require(track.id))
        try await store.addToPlaylist(playlistId: try #require(playlist.id), trackId: try #require(track.id))
        let rows = try await store.playlistTrackRows(playlistId: playlist.id!)
        #expect(rows.count == 1)
    }

    @Test func testManualPlaylistDeduplicatesInput() async throws {
        let store = try LibraryStore(inMemory: true)
        let one = try await insertTrack(store: store, title: "One")
        let two = try await insertTrack(store: store, title: "Two")
        let playlist = try await store.createManualPlaylist(
            title: "Set", trackIds: [one.id!, two.id!, one.id!])
        let rows = try await store.playlistTrackRows(playlistId: playlist.id!)
        #expect(rows.map(\.row.id) == [one.id!, two.id!])
    }

    @Test func testRepairRemovesSeededDuplicatesAndRenumbersSurvivors() async throws {
        let store = try LibraryStore(inMemory: true)
        let one = try await insertTrack(store: store, title: "One")
        let two = try await insertTrack(store: store, title: "Two")
        let playlist = try await store.createManualPlaylist(title: "Repair", trackIds: [])
        let playlistID = try #require(playlist.id)
        try await store.dbQueue.write { db in
            for (position, trackID) in [one.id!, two.id!, one.id!].enumerated() {
                var item = PlaylistItem(id: nil, playlistId: playlistID,
                                        position: position + 4, trackId: trackID,
                                        sectionTitle: nil)
                try item.insert(db)
            }
        }

        let removed = try await store.removeDuplicatePlaylistItems()
        #expect(removed == 1)
        let rows = try await store.playlistTrackRows(playlistId: playlistID)
        #expect(rows.map(\.row.id) == [one.id!, two.id!])
        #expect(rows.map(\.item.position) == [0, 1])
    }

    @Test func testMergeDuplicateFolderPlaylistsKeepsTracksAndDeletesDuplicateSource() async throws {
        let store = try LibraryStore(inMemory: true)
        let path = FolderImportIdentity.key(for: URL(fileURLWithPath: "/fixtures/Music"))
        let first = try await insertFolderSource(store: store, title: "Music", path: path)
        let second = try await insertFolderSource(store: store, title: "Music", path: path)
        let firstTrack = try await insertTrack(store: store, source: first, title: "One")
        let secondTrack = try await insertTrack(store: store, source: second, title: "Two")
        let firstPlaylist = try await store.insertPlaylist(Playlist(
            id: nil, title: "Music", kind: .folder, sourceId: first.id,
            folderBookmark: nil, watch: false))
        let secondPlaylist = try await store.insertPlaylist(Playlist(
            id: nil, title: "Music", kind: .folder, sourceId: second.id,
            folderBookmark: nil, watch: false))
        try await store.addToPlaylist(playlistId: firstPlaylist.id!, trackId: firstTrack.id!)
        try await store.addToPlaylist(playlistId: secondPlaylist.id!, trackId: secondTrack.id!)

        let merged = try await store.mergeDuplicateFolderPlaylists()
        #expect(merged == 1)
        let folderPlaylists = try await store.allPlaylists().filter { $0.kind == .folder }
        #expect(folderPlaylists.count == 1)
        let rows = try await store.playlistTrackRows(playlistId: folderPlaylists[0].id!)
        #expect(rows.map(\.row.track.title) == ["One", "Two"])
        let sources = try await store.allSources()
        #expect(sources.filter { $0.folderPath == path }.count == 1)
    }

    @Test func testFolderIdentityNormalizesEquivalentPaths() {
        #expect(FolderImportIdentity.key(for: URL(fileURLWithPath: "/a/b")) == FolderImportIdentity.key(for: URL(fileURLWithPath: "/a/b/")))
        #expect(FolderImportIdentity.key(for: URL(fileURLWithPath: "/a/b")) == FolderImportIdentity.key(for: URL(fileURLWithPath: "/a/./b")))
    }

    private func insertTrack(store: LibraryStore, title: String) async throws -> Track {
        let source: Source
        if let existing = try await store.firstSource(title: "Fixture", kind: .local) {
            source = existing
        } else {
            source = try await store.insertSource(Source(
                id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Fixture",
                addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
                licenseText: nil, memberCapHit: false))
        }
        return try await insertTrack(store: store, source: source, title: title)
    }

    private func insertFolderSource(store: LibraryStore, title: String, path: String) async throws -> Source {
        try await store.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: title,
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false, localIsFolder: true, folderPath: path))
    }

    private func insertTrack(store: LibraryStore, source: Source, title: String) async throws -> Track {
        try await store.insertTrack(Track(
            id: nil, albumId: nil, sourceId: source.id!, title: title, trackNo: nil,
            discNo: nil, durationSec: 1, codec: "wav", sampleRate: 44_100,
            bitDepthOrBitrate: nil, sortKey: title))
    }
}
