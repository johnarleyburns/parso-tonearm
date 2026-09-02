import Foundation
import SwiftData
import XCTest
@testable import TonearmWatchCore
import TonearmWatchProtocol

/// §8.3 installer: audio/metadata ordering, duplicate delivery, corruption, storage reserve,
/// replacement, delete/install race, and convergence after a restart.
final class WatchFileInstallerTests: XCTestCase {
    func testMetadataBeforeAudioInstallsAndReports() async throws {
        let fx = try Fixture()
        try await fx.repository.upsertTrack(.init(trackID: "one", title: "One", codec: "aac"))
        let staged = try fx.stage("one.m4a", bytes: Data("audio-bytes-one".utf8))
        let digest = try WatchFileDigest.measure(staged)

        let outcome = await fx.installer.install(
            stagedURL: staged,
            metadata: WatchAudioFileMetadata(trackID: "one", expectedBytes: digest.bytes,
                                             sha256: digest.sha256, codec: "aac"))

        XCTAssertEqual(outcome, .installed(trackID: "one", relativeFilename: "\(digest.sha256).m4a",
                                          bytes: digest.bytes))
        let ready = try await fx.repository.tracks(readyOnly: true).map(\.id)
        XCTAssertEqual(ready, ["one"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testAudioBeforeMetadataDefersThenConverges() async throws {
        let fx = try Fixture()
        let staged = try fx.stage("ghost.m4a", bytes: Data("ghost-audio".utf8))
        let digest = try WatchFileDigest.measure(staged)
        let meta = WatchAudioFileMetadata(trackID: "ghost", expectedBytes: digest.bytes, sha256: digest.sha256)

        let deferred = await fx.installer.install(stagedURL: staged, metadata: meta)
        XCTAssertEqual(deferred, .deferredAwaitingMetadata(trackID: "ghost"))
        let deferredIDs = await fx.installer.deferredTrackIDs()
        XCTAssertEqual(deferredIDs, ["ghost"])

        try await fx.repository.upsertTrack(.init(trackID: "ghost", title: "Ghost"))
        let retried = await fx.installer.retryDeferred()
        XCTAssertEqual(retried, [.installed(trackID: "ghost", relativeFilename: "\(digest.sha256).m4a",
                                           bytes: digest.bytes)])
        let ready = try await fx.repository.tracks(readyOnly: true).map(\.id)
        XCTAssertEqual(ready, ["ghost"])
        let remaining = await fx.installer.deferredTrackIDs()
        XCTAssertEqual(remaining, [])
    }

    func testDeferredFileSurvivesRestart() async throws {
        let fx = try Fixture()
        let staged = try fx.stage("later.m4a", bytes: Data("later-audio".utf8))
        let digest = try WatchFileDigest.measure(staged)
        _ = await fx.installer.install(
            stagedURL: staged,
            metadata: WatchAudioFileMetadata(trackID: "later", expectedBytes: digest.bytes, sha256: digest.sha256))

        // A fresh installer over the same directories, as after a relaunch.
        let restarted = WatchFileInstaller(repository: fx.repository, audioDirectory: fx.audio,
                                           stagingDirectory: fx.staging)
        try await fx.repository.upsertTrack(.init(trackID: "later", title: "Later"))
        let outcomes = await restarted.retryDeferred()
        XCTAssertEqual(outcomes, [.installed(trackID: "later", relativeFilename: "\(digest.sha256).m4a",
                                            bytes: digest.bytes)])
    }

    func testDuplicateDeliveryValidatesWithoutRewrite() async throws {
        let fx = try Fixture()
        try await fx.repository.upsertTrack(.init(trackID: "dup", title: "Dup"))
        let bytes = Data("dup-bytes".utf8)
        let first = try fx.stage("dup-1.m4a", bytes: bytes)
        let digest = try WatchFileDigest.measure(first)
        let meta = WatchAudioFileMetadata(trackID: "dup", expectedBytes: digest.bytes, sha256: digest.sha256)
        _ = await fx.installer.install(stagedURL: first, metadata: meta)

        let second = try fx.stage("dup-2.m4a", bytes: bytes)
        let outcome = await fx.installer.install(stagedURL: second, metadata: meta)
        XCTAssertEqual(outcome, .duplicateIgnored(trackID: "dup"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: fx.audio.path)
        XCTAssertEqual(files, ["\(digest.sha256).m4a"])
    }

    func testTruncatedFileIsRejectedAndStagingCleared() async throws {
        let fx = try Fixture()
        try await fx.repository.upsertTrack(.init(trackID: "trunc", title: "Trunc"))
        let staged = try fx.stage("trunc.m4a", bytes: Data("short".utf8))
        let digest = try WatchFileDigest.measure(staged)
        let outcome = await fx.installer.install(
            stagedURL: staged,
            metadata: WatchAudioFileMetadata(trackID: "trunc", expectedBytes: digest.bytes + 100,
                                             sha256: digest.sha256))
        XCTAssertEqual(outcome, .rejected(trackID: "trunc", WatchProtocolFault(code: .checksumMismatch)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let ready = try await fx.repository.tracks(readyOnly: true)
        XCTAssertTrue(ready.isEmpty)
    }

    func testWrongChecksumIsRejected() async throws {
        let fx = try Fixture()
        try await fx.repository.upsertTrack(.init(trackID: "bad", title: "Bad"))
        let staged = try fx.stage("bad.m4a", bytes: Data("bad-bytes".utf8))
        let digest = try WatchFileDigest.measure(staged)
        let outcome = await fx.installer.install(
            stagedURL: staged,
            metadata: WatchAudioFileMetadata(trackID: "bad", expectedBytes: digest.bytes,
                                             sha256: String(repeating: "0", count: 64)))
        XCTAssertEqual(outcome, .rejected(trackID: "bad", WatchProtocolFault(code: .checksumMismatch)))
    }

    func testUnsupportedCodecIsARejectNotARetry() async throws {
        let fx = try Fixture()
        try await fx.repository.upsertTrack(.init(trackID: "ogg", title: "Ogg"))
        let staged = try fx.stage("track.ogg", bytes: Data("vorbis".utf8))
        let digest = try WatchFileDigest.measure(staged)
        let outcome = await fx.installer.install(
            stagedURL: staged,
            metadata: WatchAudioFileMetadata(trackID: "ogg", expectedBytes: digest.bytes, sha256: digest.sha256))
        XCTAssertEqual(outcome, .rejected(trackID: "ogg", WatchProtocolFault(code: .unsupportedAudio)))
    }

    func testInsufficientStorageIsRejected() async throws {
        let fx = try Fixture(freeBytes: 1_000)
        try await fx.repository.upsertTrack(.init(trackID: "big", title: "Big"))
        let staged = try fx.stage("big.m4a", bytes: Data("some-audio".utf8))
        let digest = try WatchFileDigest.measure(staged)
        let outcome = await fx.installer.install(
            stagedURL: staged,
            metadata: WatchAudioFileMetadata(trackID: "big", expectedBytes: digest.bytes, sha256: digest.sha256))
        XCTAssertEqual(outcome, .rejected(trackID: "big", WatchProtocolFault(code: .insufficientWatchStorage)))
    }

    func testReplacementRemovesTheSupersededFileOnlyAfterCommit() async throws {
        let fx = try Fixture()
        try await fx.repository.upsertTrack(.init(trackID: "rep", title: "Rep"))
        let v1 = try fx.stage("rep-1.m4a", bytes: Data("version-one".utf8))
        let d1 = try WatchFileDigest.measure(v1)
        _ = await fx.installer.install(
            stagedURL: v1,
            metadata: WatchAudioFileMetadata(trackID: "rep", expectedBytes: d1.bytes, sha256: d1.sha256))

        let v2 = try fx.stage("rep-2.m4a", bytes: Data("version-two-is-longer".utf8))
        let d2 = try WatchFileDigest.measure(v2)
        let outcome = await fx.installer.install(
            stagedURL: v2,
            metadata: WatchAudioFileMetadata(trackID: "rep", expectedBytes: d2.bytes, sha256: d2.sha256))
        XCTAssertEqual(outcome, .installed(trackID: "rep", relativeFilename: "\(d2.sha256).m4a", bytes: d2.bytes))
        let files = try FileManager.default.contentsOfDirectory(atPath: fx.audio.path)
        XCTAssertEqual(files, ["\(d2.sha256).m4a"])
    }

    func testLateFileForDeletedTrackDoesNotResurrectIt() async throws {
        let fx = try Fixture()
        try await fx.repository.upsertTrack(.init(trackID: "gone", title: "Gone"))
        _ = try await fx.repository.removeTracks(["gone"])
        let staged = try fx.stage("gone.m4a", bytes: Data("orphaned".utf8))
        let digest = try WatchFileDigest.measure(staged)
        let outcome = await fx.installer.install(
            stagedURL: staged,
            metadata: WatchAudioFileMetadata(trackID: "gone", expectedBytes: digest.bytes, sha256: digest.sha256))
        XCTAssertEqual(outcome, .deferredAwaitingMetadata(trackID: "gone"))
        let tracks = try await fx.repository.tracks(readyOnly: false)
        XCTAssertTrue(tracks.isEmpty)
    }

    func testCrashAfterMoveBeforeCommitConvergesOnRedelivery() async throws {
        let fx = try Fixture()
        try await fx.repository.upsertTrack(.init(trackID: "crash", title: "Crash"))
        let bytes = Data("crash-audio".utf8)
        let probe = try fx.stage("probe.m4a", bytes: bytes)
        let digest = try WatchFileDigest.measure(probe)
        // Simulate step 4 having happened (file in place) with step 5 never committed.
        try FileManager.default.moveItem(at: probe, to: fx.audio.appendingPathComponent("\(digest.sha256).m4a"))

        let staged = try fx.stage("crash.m4a", bytes: bytes)
        let outcome = await fx.installer.install(
            stagedURL: staged,
            metadata: WatchAudioFileMetadata(trackID: "crash", expectedBytes: digest.bytes, sha256: digest.sha256))
        XCTAssertEqual(outcome, .installed(trackID: "crash", relativeFilename: "\(digest.sha256).m4a",
                                          bytes: digest.bytes))
        let ready = try await fx.repository.tracks(readyOnly: true).map(\.id)
        XCTAssertEqual(ready, ["crash"])
    }

    func testUnparseableMetadataIsRejectedWithoutRetainingTheFile() async throws {
        let fx = try Fixture()
        let staged = try fx.stage("junk.m4a", bytes: Data("junk".utf8))
        let outcome = await fx.installer.install(stagedURL: staged, metadata: ["nope": "1"])
        XCTAssertEqual(outcome, .rejected(trackID: "", WatchProtocolFault(code: .installationFailed)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let deferredIDs = await fx.installer.deferredTrackIDs()
        XCTAssertEqual(deferredIDs, [])
    }
}

private struct Fixture {
    let root: URL
    let audio: URL
    let staging: URL
    let inbox: URL
    let container: ModelContainer
    let repository: WatchLibraryRepository
    let installer: WatchFileInstaller

    init(freeBytes: Int64? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        audio = root.appendingPathComponent("audio")
        staging = root.appendingPathComponent("staging")
        inbox = root.appendingPathComponent("inbox")
        for dir in [audio, staging, inbox] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        container = try WatchStoreBootstrap.inMemory()
        repository = WatchLibraryRepository(container: container, audioDirectory: audio)
        let provider: (@Sendable () async -> WatchStorageSnapshot?)?
        if let freeBytes {
            provider = { WatchStorageSnapshot(readyBytes: 0, stagingBytes: 0, orphanBytes: 0,
                                              freeBytes: freeBytes, capacityBytes: freeBytes) }
        } else {
            provider = nil
        }
        installer = WatchFileInstaller(repository: repository, audioDirectory: audio,
                                       stagingDirectory: staging, storageProvider: provider)
    }

    func stage(_ name: String, bytes: Data) throws -> URL {
        let url = inbox.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }
}

final class WatchArtworkInstallerTests: XCTestCase {
    func testArtworkSuccessAndDuplicateDoNotRewrite() async throws {
        let fx = try ArtworkFixture()
        let bytes = Data("jpeg-derivative".utf8)
        let staged = try fx.stage("incoming.jpg", bytes: bytes)
        let digest = try WatchFileDigest.measure(staged)
        try await fx.repository.upsertTrack(.init(trackID: "track", title: "Track",
                                                   coverArtworkID: digest.sha256))
        let metadata = WatchArtworkFileMetadata(artworkID: digest.sha256, expectedBytes: digest.bytes,
                                                sha256: digest.sha256, role: .cover)
        let first = await fx.installer.install(stagedURL: staged, metadata: metadata)
        XCTAssertEqual(first, .installed(artworkID: digest.sha256, relativeFilename: "\(digest.sha256).jpg", bytes: digest.bytes))
        let destination = fx.artwork.appendingPathComponent("\(digest.sha256).jpg")
        let before = try Data(contentsOf: destination)
        let duplicate = try fx.stage("duplicate.jpg", bytes: bytes)
        let duplicateOutcome = await fx.installer.install(stagedURL: duplicate, metadata: metadata)
        XCTAssertEqual(duplicateOutcome, .duplicateIgnored(artworkID: digest.sha256))
        XCTAssertEqual(try Data(contentsOf: destination), before)
    }

    func testArtworkRejectsUnsupportedAndEveryIntegrityMismatch() async throws {
        let fx = try ArtworkFixture()
        let staged = try fx.stage("incoming.jpg", bytes: Data("derivative".utf8))
        let digest = try WatchFileDigest.measure(staged)
        let wrongSize = WatchArtworkFileMetadata(artworkID: digest.sha256, expectedBytes: digest.bytes + 1,
                                                 sha256: digest.sha256, role: .cover)
        let wrongSizeOutcome = await fx.installer.install(stagedURL: staged, metadata: wrongSize)
        XCTAssertEqual(wrongSizeOutcome,
                       .rejected(artworkID: digest.sha256, WatchProtocolFault(code: .checksumMismatch)))
        let unsupported = try fx.stage("incoming.gif", bytes: Data("derivative".utf8))
        let unsupportedMetadata = WatchArtworkFileMetadata(artworkID: digest.sha256, expectedBytes: digest.bytes,
                                                           sha256: digest.sha256, role: .cover)
        let unsupportedOutcome = await fx.installer.install(stagedURL: unsupported, metadata: unsupportedMetadata)
        XCTAssertEqual(unsupportedOutcome,
                       .rejected(artworkID: digest.sha256, WatchProtocolFault(code: .unsupportedArtwork)))
        let mismatch = try fx.stage("mismatch.jpg", bytes: Data("different".utf8))
        let mismatchOutcome = await fx.installer.install(stagedURL: mismatch, metadata: unsupportedMetadata)
        XCTAssertEqual(mismatchOutcome,
                       .rejected(artworkID: digest.sha256, WatchProtocolFault(code: .checksumMismatch)))
    }

    func testArtworkIDMustEqualCanonicalSHA256AndReserveIsHonoured() async throws {
        let fx = try ArtworkFixture(freeBytes: 1_000)
        let staged = try fx.stage("incoming.jpg", bytes: Data("derivative".utf8))
        let digest = try WatchFileDigest.measure(staged)
        try await fx.repository.upsertTrack(.init(trackID: "track", title: "Track", coverArtworkID: digest.sha256))
        let mismatchedID = WatchArtworkFileMetadata(artworkID: String(repeating: "A", count: 64),
                                                    expectedBytes: digest.bytes, sha256: digest.sha256, role: .cover)
        let mismatchedIDOutcome = await fx.installer.install(stagedURL: staged, metadata: mismatchedID)
        XCTAssertEqual(mismatchedIDOutcome,
                       .rejected(artworkID: String(repeating: "a", count: 64), WatchProtocolFault(code: .checksumMismatch)))
        let reserve = try fx.stage("reserve.jpg", bytes: Data("derivative".utf8))
        let metadata = WatchArtworkFileMetadata(artworkID: digest.sha256, expectedBytes: digest.bytes,
                                                sha256: digest.sha256, role: .cover)
        let reserveOutcome = await fx.installer.install(stagedURL: reserve, metadata: metadata)
        XCTAssertEqual(reserveOutcome,
                       .rejected(artworkID: digest.sha256, WatchProtocolFault(code: .insufficientWatchStorage)))
    }

    func testArtworkBeforeBindingDefersThenInstallsAndManifestListsIt() async throws {
        let fx = try ArtworkFixture()
        let staged = try fx.stage("incoming.png", bytes: Data("derivative".utf8))
        let digest = try WatchFileDigest.measure(staged)
        let metadata = WatchArtworkFileMetadata(artworkID: digest.sha256, expectedBytes: digest.bytes,
                                                sha256: digest.sha256, role: .custom)
        let deferredOutcome = await fx.installer.install(stagedURL: staged, metadata: metadata)
        XCTAssertEqual(deferredOutcome, .deferredAwaitingMetadata(artworkID: digest.sha256))
        try await fx.repository.upsertTrack(.init(trackID: "track", title: "Track",
                                                   customArtworkID: digest.sha256))
        let retryOutcomes = await fx.installer.retryDeferred()
        let manifest = try await fx.repository.manifest()
        XCTAssertEqual(retryOutcomes,
                       [.installed(artworkID: digest.sha256, relativeFilename: "\(digest.sha256).png", bytes: digest.bytes)])
        XCTAssertEqual(manifest.installedArtworkIDs, [digest.sha256])
    }
}

private struct ArtworkFixture {
    let root: URL
    let artwork: URL
    let staging: URL
    let container: ModelContainer
    let repository: WatchLibraryRepository
    let installer: WatchArtworkInstaller

    init(freeBytes: Int64? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        artwork = root.appendingPathComponent("artwork")
        staging = root.appendingPathComponent("stagingArtwork")
        for directory in [artwork, staging] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        container = try WatchStoreBootstrap.inMemory()
        repository = WatchLibraryRepository(container: container, audioDirectory: root.appendingPathComponent("audio"),
                                            artworkDirectory: artwork)
        let configuredFreeBytes = freeBytes
        let provider: (@Sendable () async -> WatchStorageSnapshot?)? = {
            guard let configuredFreeBytes else { return nil }
            return WatchStorageSnapshot(readyBytes: 0, stagingBytes: 0, orphanBytes: 0,
                                        freeBytes: configuredFreeBytes, capacityBytes: configuredFreeBytes)
        }
        installer = WatchArtworkInstaller(repository: repository, artworkDirectory: artwork,
                                          stagingDirectory: staging, storageProvider: provider)
    }

    func stage(_ name: String, bytes: Data) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url, options: .atomic)
        return url
    }
}
