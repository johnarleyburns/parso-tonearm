import Foundation
import SwiftData
import XCTest
@testable import TonearmWatchCore

final class WatchLibraryRepositoryTests: XCTestCase {
    func testCRUDRelationshipsSharedMembershipAndPartialCollections() async throws {
        let fixture = try Fixture()
        try await fixture.repository.upsertTrack(.init(trackID: "one", title: "First", artist: "Artist", albumTitle: "Album"))
        try await fixture.repository.upsertTrack(.init(trackID: "two", title: "Second", artist: "Artist", albumTitle: "Album"))
        try await fixture.repository.upsertPlaylist(.init(playlistID: "a", title: "A", trackIDs: ["one", "two"]))
        try await fixture.repository.upsertPlaylist(.init(playlistID: "b", title: "B", trackIDs: ["one"]))
        let digest = try fixture.write("one.m4a", bytes: Data("ready".utf8))
        try await fixture.repository.markAsset(trackID: "one", relativeFilename: "one.m4a", installedBytes: digest.bytes,
                                               sha256: digest.sha256, state: .ready)

        let playlists = try await fixture.repository.playlists()
        XCTAssertEqual(playlists.first { $0.id == "a" }?.readyTrackIDs, ["one"])
        XCTAssertEqual(playlists.first { $0.id == "b" }?.readyTrackIDs, ["one"])
        XCTAssertEqual(playlists.first { $0.id == "a" }?.isPartial, true)
        XCTAssertEqual(playlists.first { $0.id == "b" }?.isPartial, false)
        let readyIDs = try await fixture.repository.tracks(readyOnly: true).map(\.id)
        XCTAssertEqual(readyIDs, ["one"])
    }

    func testFullTrackMetadataRoundTripsThroughSnapshots() async throws {
        let fixture = try Fixture()
        try await fixture.repository.upsertTrack(.init(
            trackID: "full", title: "Full", artist: "Artist", albumTitle: "Album", durationSeconds: 214.5,
            trackNumber: 3, discNumber: 2, artworkID: "art-1", localThumbnailFilename: "art-1.jpg",
            codec: "aac", expectedBytes: 4_096, expectedSHA256: "deadbeef", phoneRevision: 7))
        let stored = try await fixture.repository.tracks()
        let track = try XCTUnwrap(stored.first)
        XCTAssertEqual(track.durationSeconds, 214.5)
        XCTAssertEqual(track.trackNumber, 3)
        XCTAssertEqual(track.discNumber, 2)
        XCTAssertEqual(track.artworkID, "art-1")
        XCTAssertEqual(track.codec, "aac")
        XCTAssertEqual(track.phoneRevision, 7)
        XCTAssertNil(track.localFilename)
        XCTAssertFalse(track.isReady)
    }

    func testArtworkProjectionUsesInstalledCustomBeforeCover() async throws {
        let fixture = try Fixture()
        try await fixture.repository.upsertTrack(.init(trackID: "art", title: "Art", artworkID: "legacy",
                                                        coverArtworkID: "cover", customArtworkID: "custom"))
        let context = ModelContext(fixture.container)
        context.insert(WatchArtworkAssetModel(artworkID: "cover", relativeFilename: "cover.jpg", bytes: 1,
                                              validationState: .ready))
        context.insert(WatchArtworkAssetModel(artworkID: "custom", relativeFilename: "custom.jpg", bytes: 1,
                                              validationState: .ready))
        try context.save()
        let tracks = try await fixture.repository.tracks()
        let track = try XCTUnwrap(tracks.first)
        XCTAssertEqual(track.artworkFilename, "custom.jpg")
    }

    func testArtworkGCRemovesUnreferencedAssetsButKeepsSharedReferences() async throws {
        let fixture = try Fixture()
        let fileURL = fixture.artwork.appendingPathComponent("shared.jpg")
        try Data("shared-art".utf8).write(to: fileURL)
        let digest = try WatchFileDigest.measure(fileURL)
        try await fixture.repository.upsertTrack(.init(trackID: "one", title: "One", coverArtworkID: digest.sha256))
        try await fixture.repository.upsertTrack(.init(trackID: "two", title: "Two", coverArtworkID: digest.sha256))
        let context = ModelContext(fixture.container)
        context.insert(WatchArtworkAssetModel(artworkID: digest.sha256, relativeFilename: fileURL.lastPathComponent,
                                              bytes: digest.bytes, validationState: .ready))
        try context.save()

        try await fixture.repository.upsertTrack(.init(trackID: "one", title: "One", coverArtworkID: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "shared art must survive")
        let sharedAsset = try await fixture.repository.artworkAsset(artworkID: digest.sha256)
        XCTAssertNotNil(sharedAsset)

        try await fixture.repository.removeTracks(["two"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "zero-reference art must be swept")
        let removedAsset = try await fixture.repository.artworkAsset(artworkID: digest.sha256)
        XCTAssertNil(removedAsset)
    }

    func testArtworkReconciliationAdoptsHashValidOrphansAndInvalidatesCorruptRows() async throws {
        let fixture = try Fixture()
        let validURL = fixture.artwork.appendingPathComponent("orphan.jpg")
        try Data("valid-art".utf8).write(to: validURL)
        let validDigest = try WatchFileDigest.measure(validURL)
        let canonicalURL = fixture.artwork.appendingPathComponent("\(validDigest.sha256).jpg")
        try FileManager.default.moveItem(at: validURL, to: canonicalURL)
        try await fixture.repository.reconcileArtworkFiles()
        let adoptedManifest = try await fixture.repository.manifest()
        XCTAssertEqual(adoptedManifest.installedArtworkIDs, [validDigest.sha256])

        let missingID = String(repeating: "e", count: 64)
        let context = ModelContext(fixture.container)
        context.insert(WatchArtworkAssetModel(artworkID: missingID, relativeFilename: "\(missingID).png",
                                              bytes: 1, validationState: .ready))
        try context.save()
        try await fixture.repository.reconcileArtworkFiles()
        let missingAsset = try await fixture.repository.artworkAsset(artworkID: missingID)
        let reconciledManifest = try await fixture.repository.manifest()
        XCTAssertEqual(missingAsset?.validationState, .corrupt)
        XCTAssertEqual(reconciledManifest.installedArtworkIDs, [validDigest.sha256])
    }

    // §5.4: a late-arriving older revision is acknowledged, never applied over newer metadata.
    func testStaleRevisionIsAcknowledgedButNotApplied() async throws {
        let fixture = try Fixture()
        let inserted = try await fixture.repository.upsertTrack(.init(trackID: "t", title: "New Title", phoneRevision: 5))
        let stale = try await fixture.repository.upsertTrack(.init(trackID: "t", title: "Old Title", phoneRevision: 2))
        let current = try await fixture.repository.upsertTrack(.init(trackID: "t", title: "Newer Title", phoneRevision: 9))
        XCTAssertEqual([inserted, stale, current], [.inserted, .staleIgnored, .updated])
        let titles = try await fixture.repository.tracks().map(\.title)
        XCTAssertEqual(titles, ["Newer Title"])

        try await fixture.repository.upsertPlaylist(.init(playlistID: "p", title: "P", trackIDs: ["t"], phoneRevision: 4))
        let stalePlaylist = try await fixture.repository.upsertPlaylist(
            .init(playlistID: "p", title: "P", trackIDs: [], phoneRevision: 1), desiredOnWatch: true)
        XCTAssertEqual(stalePlaylist, .staleIgnored)
        // The stale membership edit is dropped, but the watch-local desire flag still lands.
        let members = try await fixture.repository.playlists().first?.trackIDs
        XCTAssertEqual(members, ["t"])
    }

    func testNormalizedSearchRanksTitleBeforeArtistAndIgnoresDiacritics() async throws {
        let fixture = try Fixture()
        try await fixture.repository.upsertTrack(.init(trackID: "title", title: "Beyonce Halo", artist: "Someone"))
        try await fixture.repository.upsertTrack(.init(trackID: "artist", title: "Halo", artist: "Beyoncé"))
        try await fixture.repository.upsertTrack(.init(trackID: "album", title: "Other", artist: "Nobody", albumTitle: "Beyonce Live"))
        for id in ["title", "artist", "album"] {
            let digest = try fixture.write("\(id).m4a", bytes: Data(id.utf8))
            try await fixture.repository.markAsset(trackID: id, relativeFilename: "\(id).m4a",
                                                   installedBytes: digest.bytes, sha256: digest.sha256, state: .ready)
        }
        let result = try await fixture.repository.search("BEYONCÉ", readyOnly: true).map(\.id)
        XCTAssertEqual(result, ["title", "artist", "album"])
        // Every term must match somewhere, but not all in the same column: "Halo" by "Beyoncé"
        // satisfies both terms across title and artist, and ranks below the title-only match.
        let bothTerms = try await fixture.repository.search("beyonce halo").map(\.id)
        let unmatchedTerm = try await fixture.repository.search("beyonce nonsense").map(\.id)
        let blank = try await fixture.repository.search("   ").map(\.id)
        XCTAssertEqual(bothTerms, ["title", "artist"])
        XCTAssertEqual(unmatchedTerm, [])
        XCTAssertEqual(blank, [])
    }

    func testSearchExcludesTracksWithoutReadyAudioUnlessAsked() async throws {
        let fixture = try Fixture()
        try await fixture.repository.upsertTrack(.init(trackID: "metadata-only", title: "Pending"))
        let readyOnly = try await fixture.repository.search("pending", readyOnly: true).map(\.id)
        let everything = try await fixture.repository.search("pending", readyOnly: false).map(\.id)
        XCTAssertEqual(readyOnly, [])
        XCTAssertEqual(everything, ["metadata-only"])
    }

    func testManifestAndStorageCountOnlyReadyAssets() async throws {
        let fixture = try Fixture()
        for id in ["ready", "installing"] { try await fixture.repository.upsertTrack(.init(trackID: id, title: id)) }
        try await fixture.repository.markAsset(trackID: "ready", relativeFilename: "ready.m4a", installedBytes: 10, sha256: "a", state: .ready)
        try await fixture.repository.markAsset(trackID: "installing", relativeFilename: "part.tmp", installedBytes: 4, sha256: "b", state: .installing)
        _ = try fixture.write("orphan.m4a", bytes: Data(repeating: 1, count: 3))
        let manifest = try await fixture.repository.manifest(), storage = try await fixture.repository.storage()
        XCTAssertEqual(manifest.readyTrackIDs, ["ready"]); XCTAssertEqual(manifest.installedBytes, 10)
        XCTAssertEqual(storage.readyBytes, 10)
        XCTAssertEqual(storage.stagingBytes, 4)
        XCTAssertEqual(storage.orphanBytes, 3)
    }

    func testManifestIDIsStableAcrossInsertionOrderAndChangesWithContent() async throws {
        let first = try Fixture(), second = try Fixture()
        for (repository, ids) in [(first.repository, ["a", "b"]), (second.repository, ["b", "a"])] {
            for id in ids {
                try await repository.upsertTrack(.init(trackID: id, title: id))
                try await repository.markAsset(trackID: id, relativeFilename: "\(id).m4a", installedBytes: 1, sha256: id, state: .ready)
            }
        }
        let a = try await first.repository.manifest(), b = try await second.repository.manifest()
        XCTAssertEqual(a.manifestID, b.manifestID)
        XCTAssertEqual(a.readyTrackIDs, ["a", "b"])
        try await second.repository.markAsset(trackID: "a", relativeFilename: "a.m4a", installedBytes: 2, sha256: "a", state: .ready)
        let changed = try await second.repository.manifest()
        XCTAssertNotEqual(a.manifestID, changed.manifestID)
    }

    // §2.5: reserve the greater of 500 MB or 10% of free capacity before accepting a batch.
    func testStorageReserveIsTheGreaterOfFiveHundredMegabytesOrTenPercent() {
        let small = WatchStorageSnapshot(readyBytes: 0, stagingBytes: 0, orphanBytes: 0, freeBytes: 1_000_000_000)
        XCTAssertEqual(small.reserveBytes, 500_000_000)
        XCTAssertTrue(small.canAccept(bytes: 400_000_000))
        XCTAssertFalse(small.canAccept(bytes: 600_000_000))

        let large = WatchStorageSnapshot(readyBytes: 0, stagingBytes: 0, orphanBytes: 0, freeBytes: 20_000_000_000)
        XCTAssertEqual(large.reserveBytes, 2_000_000_000)
        XCTAssertTrue(large.canAccept(bytes: 18_000_000_000))
        XCTAssertFalse(large.canAccept(bytes: 18_000_000_001))
        XCTAssertFalse(large.canAccept(bytes: -1))
    }

    func testReconciliationMarksMissingAndCorruptAndRetainsOrphans() async throws {
        let fixture = try Fixture()
        for id in ["missing", "corrupt"] { try await fixture.repository.upsertTrack(.init(trackID: id, title: id)) }
        try await fixture.repository.markAsset(trackID: "missing", relativeFilename: "missing.m4a", installedBytes: 2, sha256: "x", state: .ready)
        _ = try fixture.write("corrupt.m4a", bytes: Data("bad".utf8))
        try await fixture.repository.markAsset(trackID: "corrupt", relativeFilename: "corrupt.m4a", installedBytes: 3, sha256: "wrong", state: .ready)
        _ = try fixture.write("preserved.m4a", bytes: Data("orphan".utf8))
        let result = try await fixture.repository.reconcileFiles()
        XCTAssertEqual(result.missingTrackIDs, ["missing"]); XCTAssertEqual(result.corruptTrackIDs, ["corrupt"])
        XCTAssertEqual(result.orphans.map(\.relativeFilename), ["preserved.m4a"])
        let ready = try await fixture.repository.tracks(readyOnly: true)
        XCTAssertTrue(ready.isEmpty)
        // The file that failed validation is still on disk — reconciliation never deletes audio.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audio.appendingPathComponent("corrupt.m4a").path))
    }

    func testOrphanAdoptionAndPlaylistSearch() async throws {
        let fixture = try Fixture(), data = Data("recover-me".utf8)
        try await fixture.repository.upsertTrack(.init(trackID: "recover", title: "Recovered"))
        try await fixture.repository.upsertPlaylist(.init(playlistID: "night", title: "Nîght Drive", trackIDs: ["recover"]))
        _ = try fixture.write("orphan.m4a", bytes: data)
        let reconciliation = try await fixture.repository.reconcileFiles()
        let orphan = try XCTUnwrap(reconciliation.orphans.first)
        try await fixture.repository.adoptOrphan(orphan, forTrackID: "recover")
        let ready = try await fixture.repository.tracks(readyOnly: true)
        let playlists = try await fixture.repository.searchPlaylists("night")
        XCTAssertEqual(ready.map(\.id), ["recover"]); XCTAssertEqual(playlists.map(\.id), ["night"])
    }

    // A rebuilt store must not call an unrelated file "ready" just because a track is waiting for one.
    func testOrphanAdoptionRejectsFilesThatContradictTrackMetadata() async throws {
        let fixture = try Fixture()
        let digest = try fixture.write("candidate.m4a", bytes: Data("actual-audio".utf8))
        try await fixture.repository.upsertTrack(.init(trackID: "expects", title: "Expects",
                                                       expectedBytes: digest.bytes, expectedSHA256: String(repeating: "0", count: 64)))
        try await fixture.repository.upsertTrack(.init(trackID: "wrong-size", title: "Wrong Size",
                                                       expectedBytes: digest.bytes + 1, expectedSHA256: digest.sha256))
        let reconciliation = try await fixture.repository.reconcileFiles()
        let orphan = try XCTUnwrap(reconciliation.orphans.first)

        await assertThrows(WatchLibraryError.invalidOrphan("expects")) {
            try await fixture.repository.adoptOrphan(orphan, forTrackID: "expects")
        }
        await assertThrows(WatchLibraryError.invalidOrphan("wrong-size")) {
            try await fixture.repository.adoptOrphan(orphan, forTrackID: "wrong-size")
        }
        await assertThrows(WatchLibraryError.unknownTrack("nobody")) {
            try await fixture.repository.adoptOrphan(orphan, forTrackID: "nobody")
        }
        let stillPending = try await fixture.repository.tracks(readyOnly: true)
        XCTAssertTrue(stillPending.isEmpty)
    }

    func testPlaybackRestorePrunesNonReadyEntriesDeterministically() async throws {
        let fixture = try Fixture()
        for id in ["ready", "missing"] { try await fixture.repository.upsertTrack(.init(trackID: id, title: id)) }
        try await fixture.repository.markAsset(trackID: "ready", relativeFilename: "ready.m4a", installedBytes: 1, sha256: "x", state: .ready)
        let context = ModelContext(fixture.container)
        context.insert(WatchPlaybackStateModel(queueTrackIDs: ["missing", "ready"], currentIndex: 1, elapsedSeconds: 12))
        try context.save()
        let restored = try await fixture.repository.restorePlaybackState()
        XCTAssertEqual(restored?.queueTrackIDs, ["ready"]); XCTAssertEqual(restored?.currentIndex, 0)
        XCTAssertEqual(restored?.elapsedSeconds, 12)
        // Repeating the restore is stable, not progressively destructive.
        let again = try await fixture.repository.restorePlaybackState()
        XCTAssertEqual(again?.queueTrackIDs, ["ready"]); XCTAssertEqual(again?.currentIndex, 0)
    }

    func testPlaybackRestoreClearsAQueueWithNoReadyTracks() async throws {
        let fixture = try Fixture()
        try await fixture.repository.upsertTrack(.init(trackID: "gone", title: "Gone"))
        let context = ModelContext(fixture.container)
        context.insert(WatchPlaybackStateModel(queueTrackIDs: ["gone"], currentIndex: 0, elapsedSeconds: 30))
        try context.save()
        let restored = try await fixture.repository.restorePlaybackState()
        XCTAssertEqual(restored?.queueTrackIDs, [])
        XCTAssertEqual(restored?.currentIndex, 0)
        XCTAssertEqual(restored?.elapsedSeconds, 0)
    }

    func testDeterministicSeedCanRunRepeatedly() async throws {
        let fixture = try Fixture()
        try await fixture.repository.seedDeterministicFixture(); try await fixture.repository.seedDeterministicFixture()
        let trackIDs = try await fixture.repository.tracks().map(\.id)
        let playlistIDs = try await fixture.repository.playlists().map(\.id)
        XCTAssertEqual(trackIDs, ["fixture-track"]); XCTAssertEqual(playlistIDs, ["fixture-playlist"])
    }

    func testAllSchemaModelsPersist() throws {
        let container = try WatchStoreBootstrap.inMemory(), context = ModelContext(container)
        context.insert(WatchDownloadJobModel(requestID: "request", trackID: "track", rootIDs: ["root"], attemptToken: "attempt"))
        context.insert(WatchDownloadRootModel(rootID: "root", kind: .playlist, sourceID: "playlist", desiredTrackIDs: ["track"]))
        context.insert(WatchPlaybackStateModel(queueTrackIDs: ["track"], currentIndex: 0))
        context.insert(WatchSyncStateModel(protocolVersion: 1, pairedLibraryIdentity: "library"))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<WatchDownloadJobModel>()).first?.state, .queued)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WatchDownloadRootModel>()).first?.kind, .playlist)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WatchPlaybackStateModel>()).first?.queueTrackIDs, ["track"])
        XCTAssertEqual(try context.fetch(FetchDescriptor<WatchSyncStateModel>()).first?.pairedLibraryIdentity, "library")
    }

    func testUnknownRawValuesDecodeToSafeStatesRatherThanCrashing() throws {
        let container = try WatchStoreBootstrap.inMemory(), context = ModelContext(container)
        let job = WatchDownloadJobModel(requestID: "r", trackID: "t", rootIDs: [], attemptToken: "a")
        let root = WatchDownloadRootModel(rootID: "root", kind: .track, sourceID: "s", desiredTrackIDs: [])
        let asset = WatchAssetModel(trackID: "t", relativeFilename: "t.m4a", installedBytes: 1, sha256: "x", validationState: .ready)
        context.insert(job); context.insert(root); context.insert(asset)
        job.stateRaw = "from-a-newer-build"; root.kindRaw = "from-a-newer-build"; asset.validationStateRaw = "from-a-newer-build"
        try context.save()
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(root.kind, .track)
        // An unrecognized validation state must never read as playable.
        XCTAssertEqual(asset.validationState, .corrupt)
    }

    func testPersistentStoreRelaunches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("library.store"), audio = root.appendingPathComponent("audio")
        var first: WatchStoreBootstrapResult? = WatchStoreBootstrap.open(storeURL: store, audioDirectory: audio)
        let repository = WatchLibraryRepository(container: try XCTUnwrap(first?.container), audioDirectory: audio)
        try await repository.seedDeterministicFixture(); first = nil
        let second = WatchStoreBootstrap.open(storeURL: store, audioDirectory: audio)
        let reopened = WatchLibraryRepository(container: try XCTUnwrap(second.container), audioDirectory: audio)
        let reopenedIDs = try await reopened.tracks().map(\.id)
        XCTAssertEqual(second.state, .ready); XCTAssertEqual(reopenedIDs, ["fixture-track"])
    }

    /// A store written by a build that predates some of the current models must migrate forward
    /// through `WatchSchemaMigrationPlan` without losing the rows it already held.
    func testOlderContainerMigratesForwardAndKeepsItsRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("library.store"), audio = root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)

        let oldSchema = Schema([WatchStoreMetadata.self, WatchTrackModel.self, WatchAssetModel.self])
        var old: ModelContainer? = try ModelContainer(
            for: oldSchema,
            configurations: ModelConfiguration(WatchStoreBootstrap.storeName, schema: oldSchema, url: store, cloudKitDatabase: .none))
        let oldContext = ModelContext(try XCTUnwrap(old))
        oldContext.insert(WatchTrackModel(trackID: "carried", title: "Carried Over", artist: "Artist"))
        oldContext.insert(WatchStoreMetadata(key: "written-by", value: "old-build"))
        try oldContext.save()
        old = nil

        let upgraded = WatchStoreBootstrap.open(storeURL: store, audioDirectory: audio)
        XCTAssertEqual(upgraded.state, .ready, "an additive schema change must migrate, not quarantine")
        let repository = WatchLibraryRepository(container: try XCTUnwrap(upgraded.container), audioDirectory: audio)
        let carried = try await repository.tracks().map(\.id)
        let writtenBy = try await repository.metadata("written-by")
        XCTAssertEqual(carried, ["carried"])
        XCTAssertEqual(writtenBy, "old-build")
        // Entities absent from the old store are usable immediately after the upgrade.
        try await repository.upsertPlaylist(.init(playlistID: "new", title: "New", trackIDs: ["carried"]))
        let playlistIDs = try await repository.playlists().map(\.id)
        XCTAssertEqual(playlistIDs, ["new"])
    }

    func testCorruptStoreIsQuarantinedAudioPreservedAndRecoveryRepeatsSafely() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("library.store"), audio = root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data("not-a-store".utf8).write(to: store)
        try Data("music".utf8).write(to: audio.appendingPathComponent("keep.m4a"))
        let recovered = WatchStoreBootstrap.open(storeURL: store, audioDirectory: audio, now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(recovered.state, .recovered)
        let quarantine = try XCTUnwrap(recovered.quarantinedStoreURL)
        XCTAssertEqual(recovered.recoverableFiles, [.init(relativeFilename: "keep.m4a", bytes: 5)])
        // The unreadable store is moved aside for diagnosis, not deleted.
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.appendingPathComponent("library.store").path))
        let repeated = WatchStoreBootstrap.open(storeURL: store, audioDirectory: audio)
        XCTAssertEqual(repeated.state, .ready)
        XCTAssertNil(repeated.quarantinedStoreURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.appendingPathComponent("keep.m4a").path))
    }

    private func assertThrows(_ expected: WatchLibraryError, _ body: () async throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected \(expected)", file: file, line: line) }
        catch let error as WatchLibraryError { XCTAssertEqual(error, expected, file: file, line: line) }
        catch { XCTFail("unexpected error \(error)", file: file, line: line) }
    }
}

private struct Fixture {
    let root: URL
    let audio: URL
    let artwork: URL
    let container: ModelContainer
    let repository: WatchLibraryRepository
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        audio = root.appendingPathComponent("audio"); try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        artwork = root.appendingPathComponent("artwork"); try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
        container = try WatchStoreBootstrap.inMemory()
        repository = WatchLibraryRepository(container: container, audioDirectory: audio, artworkDirectory: artwork)
    }
    @discardableResult
    func write(_ name: String, bytes: Data) throws -> (sha256: String, bytes: Int64) {
        let url = audio.appendingPathComponent(name)
        try bytes.write(to: url)
        return try WatchFileDigest.measure(url)
    }
}
