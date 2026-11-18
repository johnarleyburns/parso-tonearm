import Testing
@testable import TonearmCore

/// Real reports: (1) "Add Local Folder" must not auto-add imported files to a playlist — tracks
/// land only in the folder's own Source/Album, exactly like "Add Audio Files" already does; (2)
/// "Add Audio Files" must not add files to a playlist either, only to the "Local Files" local
/// library entry. The second is already correct in the shipped code; this pins it with a real
/// test per CLAUDE.md's TDD rule ("a behavior change is not complete without its test").
@Suite struct IngestServiceLocalImportTests {
    private func makeFolder(files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in files {
            try Data(count: 2048).write(to: folder.appendingPathComponent(name))
        }
        return folder
    }

    @Test func testAddFolderCreatesNoPlaylist() async throws {
        let store = try LibraryStore(inMemory: true)
        let folder = try makeFolder(files: ["a.mp3", "b.mp3"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let playlistsBefore = try await store.allPlaylists().count
        let summary = try await IngestService().addFolder(
            folder, includeSubfolders: true, keepOrder: true, watch: false, into: store)
        #expect(summary.imported == 2)

        let playlistsAfter = try await store.allPlaylists().count
        #expect(playlistsAfter == playlistsBefore, "folder import must create no playlist")

        let source = try await store.firstSource(title: folder.lastPathComponent, kind: .local)
        let sid = try #require(source?.id)
        let tracks = try await store.tracks(forSource: sid)
        #expect(tracks.count == 2, "tracks must still be reachable via the folder's own Source")
    }

    @Test func testReimportingSameFolderOnlyAddsDeltaWithNoDuplicateSource() async throws {
        let store = try LibraryStore(inMemory: true)
        let folder = try makeFolder(files: ["a.mp3"])
        defer { try? FileManager.default.removeItem(at: folder) }

        _ = try await IngestService().addFolder(
            folder, includeSubfolders: true, keepOrder: true, watch: false, into: store)
        try Data(count: 4096).write(to: folder.appendingPathComponent("b.mp3"))

        let summary = try await IngestService().addFolder(
            folder, includeSubfolders: true, keepOrder: true, watch: false, into: store)
        #expect(summary.imported == 1, "re-picking the same folder must only import the new file")

        let matchingSources = try await store.allSources().filter {
            $0.kind == .local && $0.title == folder.lastPathComponent
        }
        #expect(matchingSources.count == 1, "must not create a duplicate Source for the same folder")
    }

    @Test func testAddFilesCreatesNoPlaylistAndReusesLocalFilesSource() async throws {
        let store = try LibraryStore(inMemory: true)
        let folder = try makeFolder(files: ["one.mp3", "two.mp3"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["one.mp3", "two.mp3"].map { folder.appendingPathComponent($0) }

        let playlistsBefore = try await store.allPlaylists().count
        let summary1 = try await IngestService().addFiles([urls[0]], into: store)
        let summary2 = try await IngestService().addFiles([urls[1]], into: store)
        #expect(summary1.imported == 1)
        #expect(summary2.imported == 1)

        let playlistsAfter = try await store.allPlaylists().count
        #expect(playlistsAfter == playlistsBefore, "adding audio files must create no playlist")

        let sources = try await store.allSources().filter { $0.title == "Local Files" && $0.kind == .local }
        #expect(sources.count == 1, "repeated imports must reuse the single 'Local Files' source, not duplicate it")
    }
}
