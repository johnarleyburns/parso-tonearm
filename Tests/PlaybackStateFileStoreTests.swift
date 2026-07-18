import XCTest
@testable import TonearmCore

final class PlaybackStateFileStoreTests: XCTestCase {

    override func setUp() {
        if let url = PlaybackStateFileStore.fileURL() {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("tmp"))
        }
    }

    override func tearDown() {
        if let url = PlaybackStateFileStore.fileURL() {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("tmp"))
        }
        super.tearDown()
    }

    func testRoundTrip() throws {
        let snap = PlaybackStateSnapshot(
            trackIDs: [1, 2], trackSyncIDs: ["a", "b"],
            currentIndex: 0, elapsed: 12, isPlaying: true,
            savedAt: Date(timeIntervalSince1970: 1_000))
        PlaybackStateFileStore.save(snap)

        let loaded = try XCTUnwrap(PlaybackStateFileStore.load())
        XCTAssertEqual(loaded.trackIDs, [1, 2])
        XCTAssertEqual(loaded.trackSyncIDs, ["a", "b"])
        XCTAssertEqual(loaded.elapsed, 12, accuracy: 0.01)
        XCTAssertTrue(loaded.isPlaying)
    }

    func testCorruptFileReturnsNilButPreservesFile() throws {
        guard let url = PlaybackStateFileStore.fileURL() else { return }
        try "not json".data(using: .utf8)!.write(to: url)

        XCTAssertNil(PlaybackStateFileStore.load(),
            "corrupt file must return nil, not crash")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
            "corrupt file must be preserved for diagnosis")
    }

    func testTmpFileLeftoverIsIgnored() throws {
        guard let url = PlaybackStateFileStore.fileURL() else { return }
        let tmp = url.appendingPathExtension("tmp")
        try "junk".data(using: .utf8)!.write(to: tmp)

        XCTAssertNil(PlaybackStateFileStore.load(),
            "tmp leftover must not be read")
    }

    func testMaxSavedAtSelectionViaStore() throws {
        // Clean up any lingering file tier from other tests
        if let url = PlaybackStateFileStore.fileURL() {
            try? FileManager.default.removeItem(at: url)
        }
        let name = "test.filestore.\(UUID())"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }

        PlaybackStateStore.defaultsProvider = { suite }
        defer { PlaybackStateStore.defaultsProvider = { PlaybackStateStore.sharedDefaults() } }

        let older = PlaybackStateSnapshot(
            trackIDs: [1], currentIndex: 0, elapsed: 5,
            isPlaying: false, savedAt: Date(timeIntervalSince1970: 100))
        let newer = PlaybackStateSnapshot(
            trackIDs: [2], currentIndex: 0, elapsed: 10,
            isPlaying: true, savedAt: Date(timeIntervalSince1970: 200))

        PlaybackStateFileStore.save(older)
        PlaybackStateStore.save(newer, defaults: suite)

        // When loading without explicit defaults → max-by-savedAt
        let loaded = PlaybackStateStore.load()
        XCTAssertEqual(loaded?.trackIDs, [2], "must return newer snapshot")
    }
}
