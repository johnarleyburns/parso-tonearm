import Foundation
import SwiftData
import XCTest
@testable import TonearmWatchCore
import TonearmWatchProtocol

/// `WatchSyncActor` turns everything the link reports into local SwiftData truth. These exercise it
/// directly — no duplex link — so the installer/repository interplay is what is under test.
final class WatchSyncActorTests: XCTestCase {
    func testLocalOnlyWatchDropsLegacyCatalogButPreservesInstalledAudioAndSelectedMetadata() async throws {
        let fx = try Fixture()
        try await fx.repository.upsertTrack(.init(trackID: "installed", title: "Installed", albumTitle: "Downloaded Album"))
        let installedURL = fx.audio.appendingPathComponent("installed.m4a")
        try Data("validated audio".utf8).write(to: installedURL)
        let digest = try WatchFileDigest.measure(installedURL)
        try await fx.repository.markAsset(trackID: "installed", relativeFilename: "installed.m4a",
            installedBytes: digest.bytes, sha256: digest.sha256, state: .ready)
        try await fx.repository.upsertTrack(.init(trackID: "remote", title: "Full phone catalog"))
        try await fx.repository.upsertPlaylist(.init(playlistID: "remote-list", title: "Not on watch", trackIDs: ["remote"]))
        let sync = WatchSyncActor(repository: fx.repository, installer: fx.installer, localDownloadsOnly: true)
        await sync.removeLegacyCatalogMetadata()
        let rows = try await fx.repository.tracks()
        XCTAssertEqual(rows.map(\.id), ["installed"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: installedURL.path))
        await sync.didReceiveCatalogPage(.init(catalogID: "old", revision: 20, pageIndex: 0, pageCount: 1,
            tracks: [.init(trackID: "remote", title: "Unselected")], playlists: []))
        let ignored = try await fx.repository.tracks()
        XCTAssertEqual(ignored.map(\.id), ["installed"])
        await sync.didReceiveCatalogPage(.init(catalogID: "selected", revision: 21, pageIndex: 0, pageCount: 1,
            tracks: [.init(trackID: "queued", title: "Selected audio")], playlists: [], downloadSelectionOnly: true))
        let selected = try await fx.repository.tracks()
        XCTAssertEqual(Set(selected.map(\.id)), ["installed", "queued"])
        let playable = try await fx.repository.tracks(readyOnly: true)
        XCTAssertEqual(playable.map(\.id), ["installed"])
    }
    func testWholeAACSurvivesUnrelatedCatalogPagesUntilItsMetadataArrives() async throws {
        let fx = try Fixture()
        let sync = WatchSyncActor(repository: fx.repository, installer: fx.installer, requiresNormalizedAAC: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Audio/ambient-ocean-watch-aac128.m4a")
        let incoming = try fx.stage("delivered.m4a", bytes: Data(contentsOf: source))
        let digest = try WatchFileDigest.measure(incoming)
        await sync.didReceiveAudioFile(at: incoming, metadata: WatchAudioFileMetadata(trackID: "late-audio",
            expectedBytes: digest.bytes, sha256: digest.sha256, codec: "aac", fileExtension: "m4a").dictionary)
        let retained = fx.staging.appendingPathComponent("late-audio.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        await sync.didReceiveCatalogPage(.init(catalogID: "large-library", revision: 1,
            pageIndex: 0, pageCount: 2, tracks: [.init(trackID: "unrelated", title: "Other music")], playlists: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path),
            "Retrying before this track's metadata arrives must not delete Apple's delivered audio")
        let restartedInstaller = WatchFileInstaller(repository: fx.repository, audioDirectory: fx.audio,
            stagingDirectory: fx.staging)
        for _ in 0..<3 {
            let outcomes = await restartedInstaller.retryDeferred()
            XCTAssertEqual(outcomes, [.deferredAwaitingMetadata(trackID: "late-audio")])
            XCTAssertEqual(try WatchFileDigest.measure(retained).sha256, digest.sha256)
        }
        await sync.didReceiveCatalogPage(.init(catalogID: "large-library", revision: 1,
            pageIndex: 1, pageCount: 2, tracks: [.init(trackID: "late-audio", title: "Late catalog audio")], playlists: []))
        let ready = try await fx.repository.manifest().readyTrackIDs
        XCTAssertEqual(ready, ["late-audio"], "Installation must finish without a second phone transfer")
    }
    func testRejectedMetadataContextIsReportedAsFailureNotQueuedSuccess() async throws {
        let fx = try Fixture()
        let diagnostics = WatchDiagnosticsRecorder()
        let sync = WatchSyncActor(repository: fx.repository, installer: fx.installer, diagnostics: diagnostics)
        let coordinator = WatchConnectivityCoordinator(transport: RejectingMetadataTransport())
        await sync.setCoordinator(coordinator)
        await sync.publishPeriodicStatus()
        let events = await diagnostics.events().filter { $0.category == .manifestConvergence }
        XCTAssertEqual(events.last?.stateCode, "reportQueueFailed")
        XCTAssertFalse(events.contains { $0.stateCode == "reported" })
        let accepted = await coordinator.publishManifestContext(.init(manifestID: "empty", readyTrackIDs: [], installedBytes: 0))
        XCTAssertFalse(accepted)
    }
    func testOfflinePlaylistRootInstallsAudioAndLaterCatalogEnrichesPlaceholders() async throws {
        let fx = try Fixture()
        let file = try fx.stage("home.m4a", bytes: Data("home-audio".utf8))
        let digest = try WatchFileDigest.measure(file)
        await fx.syncActor.didReceiveAudioFile(at: file, metadata: WatchAudioFileMetadata(
            trackID: "home", expectedBytes: digest.bytes, sha256: digest.sha256).dictionary)
        // This fixture has no live phone coordinator: hydration cannot succeed.
        await fx.syncActor.didReceiveDownloadRoots(.init(revision: 10, roots: [
            .init(rootID: "playlist:home", kind: .playlist, sourceID: "home-playlist",
                  title: "Home Cooking", trackIDs: ["home", "other"])
        ]))
        let installed = try await fx.repository.tracks(readyOnly: true)
        XCTAssertEqual(installed.map(\.id), ["home"])
        await fx.syncActor.didReceiveCatalogPage(.init(catalogID: "older-queued-catalog", revision: 3,
            pageIndex: 0, pageCount: 1, tracks: [.init(trackID: "home", title: "Home Cooking I", artist: "Artist")],
            playlists: []))
        let enriched = try await fx.repository.tracks(readyOnly: true).first
        XCTAssertEqual(enriched?.title, "Home Cooking I")
        XCTAssertEqual(enriched?.artist, "Artist")
        XCTAssertEqual(enriched?.isReady, true)
    }

    @MainActor
    func testProductionFanoutDeliversCatalogMetadataAndUnblocksDeferredInstallation() async throws {
        let fx = try Fixture()
        let repository = fx.repository
        let suite = "watch-sync-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let receipt = Date(timeIntervalSince1970: 50_000)
        let status = WatchSyncStatusState(defaults: defaults, now: { receipt },
            latestInstallation: { try? await repository.lastAudioInstallationDate() })
        let fan = WatchFanoutObserver([fx.syncActor, status])
        let link = WatchFakeDuplexLink()
        let coordinator = WatchConnectivityCoordinator(transport: link.transport(for: .watch), observer: fan)
        await coordinator.activate(reachable: false)
        let staged = try fx.stage("cached-mp3", bytes: Data("home-cooking".utf8))
        let digest = try WatchFileDigest.measure(staged)
        await coordinator.receiveFile(staged, metadata: WatchAudioFileMetadata(trackID: "home",
            expectedBytes: digest.bytes, sha256: digest.sha256, fileExtension: "mp3").dictionary)
        XCTAssertNil(status.lastAudioInstalledAt, "Deferred delivery is not an installation")
        let page = WatchLibraryPage(catalogID: "production", revision: 3, pageIndex: 0, pageCount: 1,
            tracks: [.init(trackID: "home", title: "Home Cooking I")], playlists: [])
        let data = try WatchProtocolEnvelope.fromPhone(kind: .catalogPage, payload: page,
            libraryID: "phone", revision: 3)
        await coordinator.receiveUserInfo(data)
        let installed = try await repository.tracks(readyOnly: true)
        XCTAssertEqual(installed.map(\.id), ["home"])
        XCTAssertEqual(status.lastCatalogSyncAt, receipt)
        XCTAssertNotNil(status.lastAudioInstalledAt)
        let restored = WatchSyncStatusState(defaults: defaults)
        XCTAssertEqual(restored.lastCatalogSyncAt, receipt)
        XCTAssertEqual(restored.lastAudioInstalledAt, status.lastAudioInstalledAt)
    }

    func testCatalogPageMakesSearchAvailableAndInstallsAudioWithoutWaitingForOtherPages() async throws {
        let fx = try Fixture()
        let incoming = try fx.stage("cache-mp3", bytes: Data("home-cooking-audio".utf8))
        let digest = try WatchFileDigest.measure(incoming)
        await fx.syncActor.didReceiveAudioFile(at: incoming, metadata: WatchAudioFileMetadata(
            trackID: "home", expectedBytes: digest.bytes, sha256: digest.sha256,
            fileExtension: "mp3").dictionary)
        await fx.syncActor.didReceiveCatalogPage(.init(catalogID: "catalog", revision: 3,
            pageIndex: 1, pageCount: 2, tracks: [.init(trackID: "home", title: "Home Cooking I")], playlists: []))
        let tracks = try await fx.repository.tracks(readyOnly: false)
        let rows = WatchLocalCatalogSearch.rows(query: "Home Cooking", tracks: tracks,
            playlists: [], onWatchOnly: false)
        XCTAssertEqual(rows.map(\.id), ["home"], "A missing or slow page must not hide received catalog metadata")
        XCTAssertEqual(tracks.first?.localFilename, "\(digest.sha256).mp3")
        XCTAssertEqual(tracks.first?.isReady, true, "Catalog metadata must retry audio that arrived first")
        let deferred = await fx.installer.deferredTrackIDs()
        XCTAssertTrue(deferred.isEmpty)
        let installed = try await fx.repository.manifest().readyTrackIDs
        XCTAssertEqual(installed, ["home"])
    }

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

private struct RejectingMetadataTransport: WatchProtocolTransport {
    func isReachable() async -> Bool { false }
    func sendImmediate(_ data: Data) async throws -> Data { throw WatchProtocolFault(code: .phoneUnavailable) }
    func updateApplicationContext(_ data: Data) async throws { throw WatchProtocolFault(code: .transferFailed) }
    func transferUserInfo(_ data: Data) async {}
    func transferFile(_ url: URL, metadata: [String: String]) async throws { throw WatchProtocolFault(code: .transferFailed) }
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
