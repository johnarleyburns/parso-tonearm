import XCTest
@testable import Tonearm

/// T3.6 — folder watch: a new file appears without relaunch (simulated rescan),
/// and the watched-folder diff excludes already-tracked files.
final class FolderWatchTests: XCTestCase {

    func testNewFilesDiffExcludesTracked() {
        let a = URL(fileURLWithPath: "/music/one.mp3")
        let b = URL(fileURLWithPath: "/music/two.flac")
        let c = URL(fileURLWithPath: "/music/three.opus")
        let scanned = [a, b, c]
        let existing: Set<String> = [a.standardizedFileURL.path, b.standardizedFileURL.path]

        let fresh = FolderWatchService.newFiles(scanned: scanned, existing: existing)
        XCTAssertEqual(fresh, [c])
    }

    func testNoNewFilesWhenAllTracked() {
        let a = URL(fileURLWithPath: "/music/one.mp3")
        let existing: Set<String> = [a.standardizedFileURL.path]
        XCTAssertTrue(FolderWatchService.newFiles(scanned: [a], existing: existing).isEmpty)
    }

    func testAllFilesNewWhenNothingTracked() {
        let files = [URL(fileURLWithPath: "/m/a.mp3"), URL(fileURLWithPath: "/m/b.mp3")]
        let fresh = FolderWatchService.newFiles(scanned: files, existing: [])
        XCTAssertEqual(fresh.count, 2)
    }

    func testRescanWithoutWatchedFoldersAddsNothing() async throws {
        ProEntitlement.clear()
        defer { ProEntitlement.clear() }
        let store = try LibraryStore(inMemory: true)
        let added = await FolderWatchService.shared.rescanWatchedFolders(store: store)
        XCTAssertEqual(added, 0)
    }

    // Simulated rescan: a new file dropped into a watched folder is ingested into
    // the folder's source without a relaunch. Folder watch is free.
    func testRescanIngestsNewFileWithoutRelaunch() async throws {
        defer { ProEntitlement.clear() }

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
        let source = try XCTUnwrap(fetchedSource)
        let sid = try XCTUnwrap(source.id)
        let countBefore = try await store.tracks(forSource: sid).count

        // Drop a NEW file, then rescan (no relaunch).
        let second = folder.appendingPathComponent("second.flac")
        try Data(count: 4096).write(to: second)
        let added = await FolderWatchService.shared.rescanWatchedFolders(store: store)

        let countAfter = try await store.tracks(forSource: sid).count
        XCTAssertGreaterThanOrEqual(added, 0)
        XCTAssertGreaterThan(countAfter, countBefore, "new file should appear after rescan")
    }
}
