import Testing
@testable import TonearmCore

/// T3.6 — folder watch: a new file appears without relaunch (simulated rescan),
/// and the watched-folder diff excludes already-tracked files.
@Suite struct FolderWatchTests {

    @Test func testNewFilesDiffExcludesTracked() {
        let a = URL(fileURLWithPath: "/music/one.mp3")
        let b = URL(fileURLWithPath: "/music/two.flac")
        let c = URL(fileURLWithPath: "/music/three.opus")
        let scanned = [a, b, c]
        let existing: Set<String> = [a.standardizedFileURL.path, b.standardizedFileURL.path]

        let fresh = FolderWatchService.newFiles(scanned: scanned, existing: existing)
        #expect(fresh == [c])
    }

    @Test func testNoNewFilesWhenAllTracked() {
        let a = URL(fileURLWithPath: "/music/one.mp3")
        let existing: Set<String> = [a.standardizedFileURL.path]
        #expect(FolderWatchService.newFiles(scanned: [a], existing: existing).isEmpty)
    }

    @Test func testAllFilesNewWhenNothingTracked() {
        let files = [URL(fileURLWithPath: "/m/a.mp3"), URL(fileURLWithPath: "/m/b.mp3")]
        let fresh = FolderWatchService.newFiles(scanned: files, existing: [])
        #expect(fresh.count == 2)
    }

    @Test func testRescanWithoutWatchedFoldersAddsNothing() async throws {
        let store = try LibraryStore(inMemory: true)
        let added = await FolderWatchService.shared.rescanWatchedFolders(store: store)
        #expect(added == 0)
    }

    // Simulated rescan: a new file dropped into a watched folder is ingested into
    // the folder's source without a relaunch. Folder watch is free.
    @Test func testRescanIngestsNewFileWithoutRelaunch() async throws {

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Seed one audio file and import the folder.
        let first = folder.appendingPathComponent("first.mp3")
        try Data(count: 2048).write(to: first)

        let store = try LibraryStore(inMemory: true)
        try await IngestService().addFolder(folder, includeSubfolders: true, keepOrder: true,
                                             watch: true, into: store)

        let fetchedSource = try await store.firstSource(title: folder.lastPathComponent, kind: .local)
        let source = try #require(fetchedSource)
        let sid = try #require(source.id)
        let countBefore = try await store.tracks(forSource: sid).count

        // Drop a NEW file, then rescan (no relaunch).
        let second = folder.appendingPathComponent("second.flac")
        try Data(count: 4096).write(to: second)
        let added = await FolderWatchService.shared.rescanWatchedFolders(store: store)

        let countAfter = try await store.tracks(forSource: sid).count
        #expect(added >= 0)
        #expect(countAfter > countBefore, "new file should appear after rescan")
    }

    /// Folder imports no longer create a playlist (real report: "do not add any of the files
    /// shown to a playlist automatically"), so "watch" moved onto `Source` for every NEW import.
    /// A folder imported before that change still has its old `Playlist(kind: .folder, watch:
    /// true)` row, and must keep being watched unchanged, side by side with a brand-new,
    /// Source-only watched folder.
    @Test func testLegacyPlaylistBackedAndNewSourceBackedWatchedFoldersBothRescan() async throws {
        let store = try LibraryStore(inMemory: true)

        // Legacy representation: a Source with a Playlist(kind: .folder, watch: true) pointing
        // at it — exactly what pre-update `IngestService.addFolder` used to create.
        let legacyFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacyFolder) }
        try Data(count: 2048).write(to: legacyFolder.appendingPathComponent("legacy-first.mp3"))

        var legacySource = Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                                  title: legacyFolder.lastPathComponent, addedAt: Date(),
                                  lastResolvedAt: nil, followUpdates: false, licenseText: nil,
                                  memberCapHit: false, localIsFolder: true,
                                  folderPath: FolderImportIdentity.key(for: legacyFolder))
        legacySource = try await store.insertSource(legacySource)
        let legacySid = try #require(legacySource.id)
        _ = try await IngestService().addFiles([legacyFolder.appendingPathComponent("legacy-first.mp3")],
                                                toSourceId: legacySid, into: store)
        var legacyPlaylist = Playlist(id: nil, title: legacyFolder.lastPathComponent, kind: .folder,
                                      sourceId: legacySid,
                                      folderBookmark: BookmarkVault.makeBookmark(for: legacyFolder),
                                      watch: true)
        legacyPlaylist = try await store.insertPlaylist(legacyPlaylist)

        // Current representation: a plain `addFolder(watch: true)` import, no playlist at all.
        let newFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("new-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: newFolder) }
        try Data(count: 2048).write(to: newFolder.appendingPathComponent("new-first.mp3"))
        try await IngestService().addFolder(newFolder, includeSubfolders: true, keepOrder: true,
                                             watch: true, into: store)
        let newSource = try await store.firstSource(title: newFolder.lastPathComponent, kind: .local)
        let newSid = try #require(newSource?.id)
        let playlistCountAfterNewImport = try await store.allPlaylists().count
        #expect(playlistCountAfterNewImport == 1, "only the legacy folder has a playlist")

        // Drop a new file into each folder, then rescan once.
        try Data(count: 4096).write(to: legacyFolder.appendingPathComponent("legacy-second.flac"))
        try Data(count: 4096).write(to: newFolder.appendingPathComponent("new-second.flac"))
        let added = await FolderWatchService.shared.rescanWatchedFolders(store: store)
        #expect(added >= 2)

        let legacyCount = try await store.tracks(forSource: legacySid).count
        let newCount = try await store.tracks(forSource: newSid).count
        #expect(legacyCount == 2, "legacy playlist-backed watched folder must still pick up new files")
        #expect(newCount == 2, "new source-backed watched folder must pick up new files")
    }
}
