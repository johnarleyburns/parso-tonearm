import Foundation
import SwiftData
import XCTest
@testable import TonearmWatchCore
import TonearmWatchProtocol

/// `WatchSyncActor` turns everything the link reports into local SwiftData truth. These exercise it
/// directly — no duplex link — so the installer/repository interplay is what is under test.
final class WatchSyncActorTests: XCTestCase {
    func testTrackRootCreatesARowThenTheFileMakesItReady() async throws {
        let fx = try Fixture()
        await fx.syncActor.didReceiveDownloadRoots(WatchSetDownloadRoots(revision: 3, roots: [
            WatchDownloadRootDescriptor(rootID: "r-one", kind: .track, sourceID: "one",
                                        title: "One Song", trackIDs: ["one"])
        ]))

        let afterRoot = try await fx.repository.tracks(readyOnly: false)
        XCTAssertEqual(afterRoot.map(\.id), ["one"])
        XCTAssertEqual(afterRoot.first?.title, "One Song")
        XCTAssertFalse(afterRoot.first?.isReady ?? true)

        let staged = try fx.stage("one.m4a", bytes: Data("song-one-audio".utf8))
        let digest = try WatchFileDigest.measure(staged)
        await fx.syncActor.didReceiveAudioFile(at: staged, metadata: WatchAudioFileMetadata(
            trackID: "one", expectedBytes: digest.bytes, sha256: digest.sha256).dictionary)

        let ready = try await fx.repository.tracks(readyOnly: true).map(\.id)
        XCTAssertEqual(ready, ["one"])
    }

    func testAudioArrivingBeforeItsRootConvergesWhenTheRootLands() async throws {
        let fx = try Fixture()
        let staged = try fx.stage("early.m4a", bytes: Data("early-bird-audio".utf8))
        let digest = try WatchFileDigest.measure(staged)
        await fx.syncActor.didReceiveAudioFile(at: staged, metadata: WatchAudioFileMetadata(
            trackID: "early", expectedBytes: digest.bytes, sha256: digest.sha256).dictionary)
        let beforeRoot = try await fx.repository.tracks(readyOnly: false)
        XCTAssertTrue(beforeRoot.isEmpty)

        // The download-roots handler ends with `installer.retryDeferred()`.
        await fx.syncActor.didReceiveDownloadRoots(WatchSetDownloadRoots(revision: 1, roots: [
            WatchDownloadRootDescriptor(rootID: "r-early", kind: .track, sourceID: "early",
                                        title: "Early", trackIDs: ["early"])
        ]))
        let ready = try await fx.repository.tracks(readyOnly: true).map(\.id)
        XCTAssertEqual(ready, ["early"])
    }

    func testRemoveAssetsDropsTheTrackAndItsFile() async throws {
        let fx = try Fixture()
        try await fx.repository.upsertTrack(.init(trackID: "gone", title: "Gone"))
        let staged = try fx.stage("gone.m4a", bytes: Data("doomed-audio".utf8))
        let digest = try WatchFileDigest.measure(staged)
        _ = await fx.installer.install(stagedURL: staged, metadata: WatchAudioFileMetadata(
            trackID: "gone", expectedBytes: digest.bytes, sha256: digest.sha256))
        let filename = "\(digest.sha256).m4a"
        XCTAssertTrue(FileManager.default.fileExists(atPath: fx.audio.appendingPathComponent(filename).path))

        await fx.syncActor.didReceiveRemoveAssets(WatchRemoveAssets(revision: 9, trackIDs: ["gone"]))
        let remaining = try await fx.repository.tracks(readyOnly: false)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fx.audio.appendingPathComponent(filename).path))
    }

    func testReconciliationAdoptsAMatchingOrphanAfterAStoreRebuild() async throws {
        let fx = try Fixture()
        let bytes = Data("recovered-audio-payload".utf8)
        let staged = try fx.stage("probe.m4a", bytes: bytes)
        let digest = try WatchFileDigest.measure(staged)
        // A file on disk with no asset row — exactly what survives a store quarantine.
        try FileManager.default.moveItem(at: staged, to: fx.audio.appendingPathComponent("\(digest.sha256).m4a"))
        try await fx.repository.upsertTrack(.init(trackID: "rec", title: "Recovered",
                                                  expectedBytes: digest.bytes, expectedSHA256: digest.sha256))

        await fx.syncActor.phoneRequestedReconciliation(WatchReconciliationRequest(scope: .all, trigger: .storeRecovered))

        let ready = try await fx.repository.tracks(readyOnly: true).map(\.id)
        XCTAssertEqual(ready, ["rec"])
    }

    func testDuplicateAudioDeliveryLeavesASingleReadyRow() async throws {
        let fx = try Fixture()
        try await fx.repository.upsertTrack(.init(trackID: "dup", title: "Dup"))
        let bytes = Data("dup-delivery-audio".utf8)
        let digest = try WatchFileDigest.measure(try fx.stage("seed.m4a", bytes: bytes))
        let meta = WatchAudioFileMetadata(trackID: "dup", expectedBytes: digest.bytes, sha256: digest.sha256).dictionary

        for name in ["d1.m4a", "d2.m4a", "d3.m4a"] {
            let url = try fx.stage(name, bytes: bytes)
            await fx.syncActor.didReceiveAudioFile(at: url, metadata: meta)
        }
        let ready = try await fx.repository.tracks(readyOnly: true).map(\.id)
        XCTAssertEqual(ready, ["dup"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fx.audio.path), ["\(digest.sha256).m4a"])
    }
}

private struct Fixture {
    let root: URL
    let audio: URL
    let staging: URL
    let inbox: URL
    let repository: WatchLibraryRepository
    let installer: WatchFileInstaller
    let syncActor: WatchSyncActor

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        audio = root.appendingPathComponent("audio")
        staging = root.appendingPathComponent("staging")
        inbox = root.appendingPathComponent("inbox")
        for dir in [audio, staging, inbox] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let container = try WatchStoreBootstrap.inMemory()
        repository = WatchLibraryRepository(container: container, audioDirectory: audio)
        installer = WatchFileInstaller(repository: repository, audioDirectory: audio, stagingDirectory: staging)
        syncActor = WatchSyncActor(repository: repository, installer: installer)
    }

    func stage(_ name: String, bytes: Data) throws -> URL {
        let url = inbox.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
}
