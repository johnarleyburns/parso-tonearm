import SwiftData
import Foundation
import Testing
@testable import TonearmWatchCore

@Suite struct WatchStoreBootstrapTests {
    @Test func testResetClearsAllWatchStorageAndDefaultsButPreservesNeighboringFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = folder.appendingPathComponent(WatchStoreBootstrap.storeName)
        let legacy = folder.appendingPathComponent("WatchAudio")
        let inbox = folder.appendingPathComponent("tmp")
        let suite = "watch-reset-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
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
        #expect(try WatchStoreBootstrap.performPendingReset(root: root, legacyDirectories: [legacy],
            temporaryDirectory: inbox, defaults: defaults, defaultsDomain: suite))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent("inbox-audio.m4a").path))
        #expect(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("unrelated").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("phone-copy").path))
        #expect(defaults.object(forKey: "watch.sync.pairedLibraryID") == nil)
        #expect(defaults.object(forKey: "watch.sync.lastAppliedPhoneRevision") == nil)
        #expect(!(try WatchStoreBootstrap.performPendingReset(root: root, defaults: defaults, defaultsDomain: suite)))
    }

    @Test func testResetRejectsBroadDirectoryWithoutClearingConsent() throws {
        let suite = "watch-reset-guard-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: WatchStoreBootstrap.resetPendingKey)
        do {
            _ = try WatchStoreBootstrap.performPendingReset(root: FileManager.default.temporaryDirectory,
                defaults: defaults, defaultsDomain: suite)
            Issue.record("expected performPendingReset to throw")
        } catch {
            // Expected: a broad directory must be rejected without clearing the reset consent flag.
        }
        #expect(defaults.bool(forKey: WatchStoreBootstrap.resetPendingKey))
    }
    private enum Failure: Error { case injected }

    @Test func testInMemoryStoreRoundTrip() throws {
        let container = try WatchStoreBootstrap.inMemory()
        let context = ModelContext(container)
        context.insert(WatchStoreMetadata(key: "paired", value: "yes"))
        try context.save()
        #expect(try context.fetch(FetchDescriptor<WatchStoreMetadata>()).first?.value == "yes")
    }

    @Test func testPersistentSuccessIsReady() throws {
        let container = try WatchStoreBootstrap.inMemory()
        let result = WatchStoreBootstrap.open(persistent: { container }, recovery: { throw Failure.injected })
        #expect(result.state == .ready)
    }

    @Test func testPersistentFailureRecoversInMemory() throws {
        let fallback = try WatchStoreBootstrap.inMemory()
        let result = WatchStoreBootstrap.open(persistent: { throw Failure.injected }, recovery: { fallback })
        #expect(result.state == .recovered)
        #expect(result.container != nil)
        #expect(result.recoveryNotice != nil)
    }

    @Test func testDoubleFailureIsDegradedNotFatal() {
        let result = WatchStoreBootstrap.open(persistent: { throw Failure.injected }, recovery: { throw Failure.injected })
        #expect(result.state == .degraded)
        #expect(result.container == nil)
    }
}

@Suite struct WatchStoreLaunchResyncTests {
    @Test func testOnlyRecoveredAndDegradedRequirePhoneResync() {
        #expect(WatchStoreLaunchState.recovered.requiresPhoneResync)
        #expect(WatchStoreLaunchState.degraded.requiresPhoneResync)
        #expect(!WatchStoreLaunchState.ready.requiresPhoneResync)
        #expect(!WatchStoreLaunchState.opening.requiresPhoneResync)
    }
}
