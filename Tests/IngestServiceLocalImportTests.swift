import Foundation
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
        for (index, name) in files.enumerated() {
            // Distinct bytes per file: identical dummy data is now (correctly)
            // recognized as the same content by the fingerprint dedup.
            try Data(repeating: UInt8(index + 1), count: 2048)
                .write(to: folder.appendingPathComponent(name))
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

    /// The size+duration key cannot match when the already-imported copy has no
    /// duration metadata. The stored 128 KB sample fingerprint must still catch
    /// the same bytes at a second path.
    @Test func testSameBytesMatchByFingerprintWhenDurationMetadataIsMissing() async throws {
        let store = try LibraryStore(inMemory: true)
        let source = try #require(BuiltInContentProvider.bundledAudioURL(forChannelId: "ambient-ocean"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-hash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPath = root.appendingPathComponent("first.wav")
        let secondPath = root.appendingPathComponent("second.wav")
        try FileManager.default.copyItem(at: source, to: firstPath)
        try FileManager.default.copyItem(at: source, to: secondPath)

        let first = await IngestService().addFiles([firstPath], into: store)
        #expect(first.imported == 1)
        // Simulate a file whose metadata never yielded a duration.
        try await store.dbQueue.write { db in
            try db.execute(sql: "UPDATE track SET durationSec = NULL")
        }

        let second = await IngestService().addFiles([secondPath], into: store)
        #expect(second.imported == 0, "identical bytes must not be imported twice")
        #expect(second.skippedDuplicates == 1)
        let stored = try await store.allTrackRows()
        #expect(stored.count == 1)
        #expect(stored.first?.asset?.contentSampleHash != nil)
    }

    /// Real report: adding one file, then later adding the folder that contains
    /// the same file, duplicated it. Both paths already call the size+duration
    /// duplicate check; this pins the cross-path behavior with a real audio
    /// fixture (already-in-library bytes at a second path).
    @Test func testSameFileImportedFromASinglePathAndThenAFolderIsSkipped() async throws {
        let store = try LibraryStore(inMemory: true)
        let source = try #require(BuiltInContentProvider.bundledAudioURL(forChannelId: "ambient-ocean"))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ingest-dup-\(UUID().uuidString)", isDirectory: true)
        let firstPath = root.appendingPathComponent("single-copy.wav")
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        let secondPath = folder.appendingPathComponent("folder-copy.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: source, to: firstPath)
        try FileManager.default.copyItem(at: source, to: secondPath)

        let first = await IngestService().addFiles([firstPath], into: store)
        #expect(first.imported == 1)

        let second = try await IngestService().addFolder(
            folder, includeSubfolders: false, keepOrder: true, watch: false, into: store)
        #expect(second.imported == 0, "the same bytes at a second path must not be added twice")
        #expect(second.skippedDuplicates == 1)

        let allTracks = try await store.allTrackRows()
        #expect(allTracks.count == 1)
    }
}
