import SwiftData
import XCTest
@testable import TonearmWatchCore

final class WatchStoreBootstrapTests: XCTestCase {
    func testResetClearsAllWatchStorageAndDefaultsButPreservesNeighboringFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = folder.appendingPathComponent(WatchStoreBootstrap.storeName)
        let legacy = folder.appendingPathComponent("WatchAudio")
        let inbox = folder.appendingPathComponent("tmp")
        let suite = "watch-reset-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        for directory in [root, legacy, inbox] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for path in [root.appendingPathComponent("library.store"), root.appendingPathComponent("audio.m4a"),
                     legacy.appendingPathComponent("old.m4a"), inbox.appendingPathComponent("inbox-audio.m4a"),
                     inbox.appendingPathComponent("unrelated"), folder.appendingPathComponent("phone-copy")] {
            try Data([1, 2, 3]).write(to: path)
        }
        defaults.set("old-library", forKey: "watch.sync.pairedLibraryID")
        defaults.set(123, forKey: "watch.sync.lastAppliedPhoneRevision")
        defaults.set(true, forKey: WatchStoreBootstrap.resetPendingKey)
        XCTAssertTrue(try WatchStoreBootstrap.performPendingReset(root: root, legacyDirectories: [legacy],
            temporaryDirectory: inbox, defaults: defaults, defaultsDomain: suite))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("inbox-audio.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("unrelated").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("phone-copy").path))
        XCTAssertNil(defaults.object(forKey: "watch.sync.pairedLibraryID"))
        XCTAssertNil(defaults.object(forKey: "watch.sync.lastAppliedPhoneRevision"))
        XCTAssertFalse(try WatchStoreBootstrap.performPendingReset(root: root, defaults: defaults, defaultsDomain: suite))
    }

    func testResetRejectsBroadDirectoryWithoutClearingConsent() throws {
        let suite = "watch-reset-guard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: WatchStoreBootstrap.resetPendingKey)
        XCTAssertThrowsError(try WatchStoreBootstrap.performPendingReset(root: FileManager.default.temporaryDirectory,
            defaults: defaults, defaultsDomain: suite))
        XCTAssertTrue(defaults.bool(forKey: WatchStoreBootstrap.resetPendingKey))
    }
    private enum Failure: Error { case injected }

    func testInMemoryStoreRoundTrip() throws {
        let container = try WatchStoreBootstrap.inMemory()
        let context = ModelContext(container)
        context.insert(WatchStoreMetadata(key: "paired", value: "yes"))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<WatchStoreMetadata>()).first?.value, "yes")
    }

    func testPersistentSuccessIsReady() throws {
        let container = try WatchStoreBootstrap.inMemory()
        let result = WatchStoreBootstrap.open(persistent: { container }, recovery: { throw Failure.injected })
        XCTAssertEqual(result.state, .ready)
    }

    func testPersistentFailureRecoversInMemory() throws {
        let fallback = try WatchStoreBootstrap.inMemory()
        let result = WatchStoreBootstrap.open(persistent: { throw Failure.injected }, recovery: { fallback })
        XCTAssertEqual(result.state, .recovered)
        XCTAssertNotNil(result.container)
        XCTAssertNotNil(result.recoveryNotice)
    }

    func testDoubleFailureIsDegradedNotFatal() {
        let result = WatchStoreBootstrap.open(persistent: { throw Failure.injected }, recovery: { throw Failure.injected })
        XCTAssertEqual(result.state, .degraded)
        XCTAssertNil(result.container)
    }
}
