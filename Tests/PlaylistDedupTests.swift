import GRDB
import XCTest
@testable import TonearmCore

final class PlaylistDedupTests: XCTestCase {
    func testFirstOccurrenceWinsAndPositionsBecomeContiguous() {
        let items = [
            PlaylistItem(id: 10, playlistId: 1, position: 4, trackId: 7, sectionTitle: nil),
            PlaylistItem(id: 11, playlistId: 1, position: 8, trackId: 8, sectionTitle: nil),
            PlaylistItem(id: 12, playlistId: 1, position: 9, trackId: 7, sectionTitle: nil),
        ]
        XCTAssertEqual(PlaylistDedup.duplicateItemIDs(in: items), [12])
        XCTAssertEqual(PlaylistDedup.deduplicated(items).map(\.id), [10, 11])
        XCTAssertEqual(PlaylistDedup.deduplicated(items).map(\.position), [0, 1])
    }

    func testStoreDoesNotAddTheSameTrackTwice() async throws {
        let store = try LibraryStore(inMemory: true)
        let track = try await insertTrack(store: store, title: "One")
        let playlist = try await store.createManualPlaylist(title: "Set", trackIds: [])
        try await store.addToPlaylist(playlistId: try XCTUnwrap(playlist.id), trackId: try XCTUnwrap(track.id))
        try await store.addToPlaylist(playlistId: try XCTUnwrap(playlist.id), trackId: try XCTUnwrap(track.id))
        let rows = try await store.playlistTrackRows(playlistId: playlist.id!)
        XCTAssertEqual(rows.count, 1)
    }

    func testManualPlaylistDeduplicatesInput() async throws {
        let store = try LibraryStore(inMemory: true)
        let one = try await insertTrack(store: store, title: "One")
        let two = try await insertTrack(store: store, title: "Two")
        let playlist = try await store.createManualPlaylist(
            title: "Set", trackIds: [one.id!, two.id!, one.id!])
        let rows = try await store.playlistTrackRows(playlistId: playlist.id!)
        XCTAssertEqual(rows.map(\.row.id), [one.id!, two.id!])
    }

    func testRepairRemovesSeededDuplicatesAndRenumbersSurvivors() async throws {
        let store = try LibraryStore(inMemory: true)
        let one = try await insertTrack(store: store, title: "One")
        let two = try await insertTrack(store: store, title: "Two")
        let playlist = try await store.createManualPlaylist(title: "Repair", trackIds: [])
        let playlistID = try XCTUnwrap(playlist.id)
        try await store.dbQueue.write { db in
            for (position, trackID) in [one.id!, two.id!, one.id!].enumerated() {
                var item = PlaylistItem(id: nil, playlistId: playlistID,
                                        position: position + 4, trackId: trackID,
                                        sectionTitle: nil)
                try item.insert(db)
            }
        }

        let removed = try await store.removeDuplicatePlaylistItems()
        XCTAssertEqual(removed, 1)
        let rows = try await store.playlistTrackRows(playlistId: playlistID)
        XCTAssertEqual(rows.map(\.row.id), [one.id!, two.id!])
        XCTAssertEqual(rows.map(\.item.position), [0, 1])
    }

    func testMergeDuplicateFolderPlaylistsKeepsTracksAndDeletesDuplicateSource() async throws {
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
        XCTAssertEqual(merged, 1)
        let folderPlaylists = try await store.allPlaylists().filter { $0.kind == .folder }
        XCTAssertEqual(folderPlaylists.count, 1)
        let rows = try await store.playlistTrackRows(playlistId: folderPlaylists[0].id!)
        XCTAssertEqual(rows.map(\.row.track.title), ["One", "Two"])
        let sources = try await store.allSources()
        XCTAssertEqual(sources.filter { $0.folderPath == path }.count, 1)
    }

    func testFolderIdentityNormalizesEquivalentPaths() {
        XCTAssertEqual(FolderImportIdentity.key(for: URL(fileURLWithPath: "/a/b")),
                       FolderImportIdentity.key(for: URL(fileURLWithPath: "/a/b/")))
        XCTAssertEqual(FolderImportIdentity.key(for: URL(fileURLWithPath: "/a/b")),
                       FolderImportIdentity.key(for: URL(fileURLWithPath: "/a/./b")))
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
